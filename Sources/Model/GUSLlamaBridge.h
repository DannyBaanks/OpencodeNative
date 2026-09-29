#ifndef GUS_LLAMA_BRIDGE_H
#define GUS_LLAMA_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

typedef struct GUSLlamaContext GUSLlamaContext;

GUSLlamaContext * gus_llama_create(const char * model_path, uint32_t context_tokens, char * error, size_t error_capacity);
void gus_llama_destroy(GUSLlamaContext * context);
void gus_llama_cancel(GUSLlamaContext * context);
char * gus_llama_generate(GUSLlamaContext * context, const char * prompt, uint32_t max_tokens, char * error, size_t error_capacity);
void gus_llama_free_text(char * text);

#endif
