#include "GUSLlamaBridge.h"
#include <llama/llama.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct GUSLlamaContext {
    struct llama_model * model;
    struct llama_context * context;
    atomic_bool cancelled;
};

static pthread_once_t backend_once = PTHREAD_ONCE_INIT;
static void initialize_backend(void) { llama_backend_init(); }

static void set_error(char * output, size_t capacity, const char * message) {
    if (output == NULL || capacity == 0) return;
    snprintf(output, capacity, "%s", message == NULL ? "Unknown llama.cpp error" : message);
}

GUSLlamaContext * gus_llama_create(const char * model_path, uint32_t context_tokens, char * error, size_t error_capacity) {
    if (model_path == NULL || context_tokens < 512 || context_tokens > 4096) {
        set_error(error, error_capacity, "Invalid model path or unsupported context size (allowed: 512–4096). ");
        return NULL;
    }
    pthread_once(&backend_once, initialize_backend);

    struct llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = -1;
    struct llama_model * model = llama_model_load_from_file(model_path, model_params);
    if (model == NULL) {
        set_error(error, error_capacity, "llama.cpp could not load the verified GGUF.");
        return NULL;
    }

    struct llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = context_tokens;
    context_params.n_batch = context_tokens < 256 ? context_tokens : 256;
    context_params.n_ubatch = context_params.n_batch;
    context_params.n_threads = 4;
    context_params.n_threads_batch = 4;
    struct llama_context * context = llama_init_from_model(model, context_params);
    if (context == NULL) {
        llama_model_free(model);
        set_error(error, error_capacity, "llama.cpp could not allocate the requested context.");
        return NULL;
    }

    GUSLlamaContext * result = calloc(1, sizeof(GUSLlamaContext));
    if (result == NULL) {
        llama_free(context);
        llama_model_free(model);
        set_error(error, error_capacity, "Not enough memory for the inference context.");
        return NULL;
    }
    result->model = model;
    result->context = context;
    atomic_init(&result->cancelled, false);
    return result;
}

void gus_llama_destroy(GUSLlamaContext * context) {
    if (context == NULL) return;
    llama_free(context->context);
    llama_model_free(context->model);
    free(context);
}

void gus_llama_cancel(GUSLlamaContext * context) {
    if (context != NULL) atomic_store(&context->cancelled, true);
}

char * gus_llama_generate(GUSLlamaContext * state, const char * prompt, uint32_t max_tokens, char * error, size_t error_capacity) {
    if (state == NULL || prompt == NULL || max_tokens == 0 || max_tokens > 512) {
        set_error(error, error_capacity, "Invalid inference request.");
        return NULL;
    }
    atomic_store(&state->cancelled, false);
    llama_memory_clear(llama_get_memory(state->context), true);

    const struct llama_vocab * vocab = llama_model_get_vocab(state->model);
    size_t prompt_length = strlen(prompt);
    if (prompt_length > (size_t)INT32_MAX - 16) {
        set_error(error, error_capacity, "Prompt is too large to tokenize safely.");
        return NULL;
    }
    int32_t token_capacity = (int32_t)prompt_length + 16;
    llama_token * tokens = calloc((size_t)token_capacity, sizeof(llama_token));
    if (tokens == NULL) {
        set_error(error, error_capacity, "Not enough memory to tokenize the prompt.");
        return NULL;
    }
    int32_t token_count = llama_tokenize(vocab, prompt, (int32_t)prompt_length, tokens, token_capacity, true, true);
    if (token_count < 0) {
        int32_t required = -token_count;
        llama_token * larger = realloc(tokens, (size_t)required * sizeof(llama_token));
        if (larger == NULL) { free(tokens); set_error(error, error_capacity, "Not enough memory to tokenize the prompt."); return NULL; }
        tokens = larger;
        token_count = llama_tokenize(vocab, prompt, (int32_t)prompt_length, tokens, required, true, true);
    }
    if (token_count <= 0 || (uint32_t)token_count + max_tokens > llama_n_ctx(state->context)) {
        free(tokens);
        set_error(error, error_capacity, "Prompt exceeds the selected local context window.");
        return NULL;
    }

    // llama_decode has a hard n_batch limit (256 in our iOS context). Sending
    // the full conversation as one batch works for the first short prompt, but
    // a second turn includes the previous answer and can exceed that limit;
    // llama.cpp asserts in that case and terminates the app. Prefill in
    // sequential chunks so the memory positions continue across the prompt.
    const uint32_t batch_limit = llama_n_batch(state->context);
    if (batch_limit == 0) {
        free(tokens);
        set_error(error, error_capacity, "llama.cpp reported an invalid prompt batch size.");
        return NULL;
    }
    for (int32_t offset = 0; offset < token_count;) {
        const int32_t remaining = token_count - offset;
        const int32_t chunk_size = remaining < (int32_t)batch_limit
            ? remaining
            : (int32_t)batch_limit;
        struct llama_batch prompt_batch = llama_batch_get_one(tokens + offset, chunk_size);
        if (llama_decode(state->context, prompt_batch) != 0) {
            free(tokens);
            set_error(error, error_capacity, "llama.cpp failed while evaluating the prompt.");
            return NULL;
        }
        offset += chunk_size;
    }
    free(tokens);

    struct llama_sampler_chain_params sampler_params = llama_sampler_chain_default_params();
    struct llama_sampler * sampler = llama_sampler_chain_init(sampler_params);
    if (sampler == NULL) { set_error(error, error_capacity, "Could not initialize local sampler."); return NULL; }
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());

    size_t output_capacity = (size_t)max_tokens * 32 + 1;
    char * output = calloc(output_capacity, 1);
    if (output == NULL) {
        llama_sampler_free(sampler);
        set_error(error, error_capacity, "Not enough memory for generated text.");
        return NULL;
    }
    size_t output_length = 0;
    char piece[512];
    for (uint32_t index = 0; index < max_tokens; index++) {
        if (atomic_load(&state->cancelled)) {
            free(output);
            llama_sampler_free(sampler);
            set_error(error, error_capacity, "Generation cancelled.");
            return NULL;
        }
        llama_token token = llama_sampler_sample(sampler, state->context, -1);
        if (llama_vocab_is_eog(vocab, token)) break;
        llama_sampler_accept(sampler, token);
        int32_t piece_length = llama_token_to_piece(vocab, token, piece, (int32_t)sizeof(piece), 0, false);
        if (piece_length > 0 && output_length + (size_t)piece_length < output_capacity) {
            memcpy(output + output_length, piece, (size_t)piece_length);
            output_length += (size_t)piece_length;
            output[output_length] = '\0';
        }
        struct llama_batch next = llama_batch_get_one(&token, 1);
        if (llama_decode(state->context, next) != 0) {
            free(output);
            llama_sampler_free(sampler);
            set_error(error, error_capacity, "llama.cpp failed while generating a response.");
            return NULL;
        }
    }
    llama_sampler_free(sampler);
    return output;
}

void gus_llama_free_text(char * text) { free(text); }
