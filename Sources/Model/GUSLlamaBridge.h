#ifndef GUS_LLAMA_BRIDGE_H
#define GUS_LLAMA_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

typedef struct GUSLlamaContext GUSLlamaContext;

typedef struct GUSChatMessage {
    const char * role;     // "system", "user" or "assistant"
    const char * content;  // untrusted text; control-token spellings are neutralized
} GUSChatMessage;

typedef enum GUSTemplateSource {
    GUS_TEMPLATE_OVERRIDE = 0,  // catalog-provided builtin template name
    GUS_TEMPLATE_EMBEDDED = 1,  // tokenizer.chat_template from the GGUF
    GUS_TEMPLATE_FALLBACK = 2,  // embedded template missing/unsupported: ChatML
} GUSTemplateSource;

typedef struct GUSGenerationStats {
    double prefill_ms;
    double generate_ms;
    int32_t prompt_tokens;
    int32_t generated_tokens;
    int32_t template_source;    // GUSTemplateSource
    int32_t stopped_at_eog;     // 1 if the model ended its turn, 0 if max_tokens hit
} GUSGenerationStats;

GUSLlamaContext * gus_llama_create(const char * model_path, uint32_t context_tokens, char * error, size_t error_capacity);
void gus_llama_destroy(GUSLlamaContext * context);
void gus_llama_cancel(GUSLlamaContext * context);

/// Raw prompt generation (control tokens in `prompt` are parsed). Kept for tests.
char * gus_llama_generate(GUSLlamaContext * context, const char * prompt, uint32_t max_tokens, char * error, size_t error_capacity);

/// Formats `messages` with the model's own chat template (or `template_override`,
/// a builtin llama.cpp template name, when non-NULL) and generates greedily.
/// `stats` may be NULL.
char * gus_llama_generate_chat(GUSLlamaContext * context, const GUSChatMessage * messages, size_t message_count,
                               const char * template_override, uint32_t max_tokens,
                               GUSGenerationStats * stats, char * error, size_t error_capacity);

/// Formats without generating; returns the prompt the model would see. Free with gus_llama_free_text.
char * gus_llama_format_chat(GUSLlamaContext * context, const GUSChatMessage * messages, size_t message_count,
                             const char * template_override, int32_t * template_source,
                             char * error, size_t error_capacity);

/// Human-readable model description (architecture, size, quantization). Free with gus_llama_free_text.
char * gus_llama_model_description(GUSLlamaContext * context);

void gus_llama_free_text(char * text);

#endif
