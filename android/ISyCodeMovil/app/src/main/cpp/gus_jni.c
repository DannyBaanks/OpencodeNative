// JNI surface for dev.iyscode.movil.gus.NativeLlama.
//
// Everything interesting lives in the shared bridge (Sources/Model/GUSLlamaBridge.c),
// the same file the iOS app compiles. Text crosses the boundary as UTF-8 byte
// arrays: JNI's "modified UTF-8" strings mangle emoji and other supplementary
// characters, and model output can end in the middle of a code point.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "GUSLlamaBridge.h"
#include "GUSSignalTrap.h"

static void throw_state(JNIEnv * env, const char * message) {
    jclass cls = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (cls != NULL) (*env)->ThrowNew(env, cls, message);
}

static char * copy_bytes(JNIEnv * env, jbyteArray array) {
    jsize length = (*env)->GetArrayLength(env, array);
    char * out = malloc((size_t)length + 1);
    if (out == NULL) return NULL;
    (*env)->GetByteArrayRegion(env, array, 0, length, (jbyte *)out);
    out[length] = '\0';
    return out;
}

JNIEXPORT jlong JNICALL
Java_dev_iyscode_movil_gus_NativeLlama_nativeCreate(JNIEnv * env, jclass cls, jstring path, jint context_tokens) {
    (void)cls;
    const char * c_path = (*env)->GetStringUTFChars(env, path, NULL);
    if (c_path == NULL) return 0;
    char error[512] = {0};
    GUSLlamaContext * ctx = gus_llama_create(c_path, (uint32_t)context_tokens, error, sizeof(error));
    (*env)->ReleaseStringUTFChars(env, path, c_path);
    if (ctx == NULL) {
        throw_state(env, error[0] ? error : "llama.cpp could not load the model.");
        return 0;
    }
    return (jlong)(intptr_t)ctx;
}

JNIEXPORT void JNICALL
Java_dev_iyscode_movil_gus_NativeLlama_nativeDestroy(JNIEnv * env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    gus_llama_destroy((GUSLlamaContext *)(intptr_t)handle);
}

JNIEXPORT void JNICALL
Java_dev_iyscode_movil_gus_NativeLlama_nativeCancel(JNIEnv * env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    gus_llama_cancel((GUSLlamaContext *)(intptr_t)handle);
}

// stats (length >= 6): prefill_ms, generate_ms, prompt_tokens, generated_tokens,
// template_source, stopped_at_eog.
JNIEXPORT jbyteArray JNICALL
Java_dev_iyscode_movil_gus_NativeLlama_nativeGenerateChat(JNIEnv * env, jclass cls, jlong handle,
                                                          jobjectArray roles, jobjectArray contents,
                                                          jstring template_override, jint max_tokens,
                                                          jdoubleArray stats_out) {
    (void)cls;
    GUSLlamaContext * ctx = (GUSLlamaContext *)(intptr_t)handle;
    jsize count = (*env)->GetArrayLength(env, roles);
    if (ctx == NULL || count <= 0 || count != (*env)->GetArrayLength(env, contents)) {
        throw_state(env, "Invalid chat request.");
        return NULL;
    }
    GUSChatMessage * messages = calloc((size_t)count, sizeof(GUSChatMessage));
    char ** owned = calloc((size_t)count * 2, sizeof(char *));
    jbyteArray result = NULL;
    const char * c_template = NULL;
    if (messages == NULL || owned == NULL) { throw_state(env, "Not enough memory."); goto done; }

    for (jsize i = 0; i < count; i++) {
        jstring role = (jstring)(*env)->GetObjectArrayElement(env, roles, i);
        jbyteArray content = (jbyteArray)(*env)->GetObjectArrayElement(env, contents, i);
        const char * c_role = (*env)->GetStringUTFChars(env, role, NULL);
        owned[2 * i] = c_role ? strdup(c_role) : NULL;
        if (c_role) (*env)->ReleaseStringUTFChars(env, role, c_role);
        owned[2 * i + 1] = copy_bytes(env, content);
        (*env)->DeleteLocalRef(env, role);
        (*env)->DeleteLocalRef(env, content);
        if (owned[2 * i] == NULL || owned[2 * i + 1] == NULL) { throw_state(env, "Not enough memory."); goto done; }
        messages[i].role = owned[2 * i];
        messages[i].content = owned[2 * i + 1];
    }
    if (template_override != NULL) c_template = (*env)->GetStringUTFChars(env, template_override, NULL);

    GUSGenerationStats stats;
    char error[512] = {0};
    char * text = gus_llama_generate_chat(ctx, messages, (size_t)count, c_template, (uint32_t)max_tokens,
                                          &stats, error, sizeof(error));
    if (stats_out != NULL && (*env)->GetArrayLength(env, stats_out) >= 6) {
        jdouble values[6] = { stats.prefill_ms, stats.generate_ms, (jdouble)stats.prompt_tokens,
                              (jdouble)stats.generated_tokens, (jdouble)stats.template_source,
                              (jdouble)stats.stopped_at_eog };
        (*env)->SetDoubleArrayRegion(env, stats_out, 0, 6, values);
    }
    if (text == NULL) {
        throw_state(env, error[0] ? error : "Local inference failed.");
        goto done;
    }
    jsize length = (jsize)strlen(text);
    result = (*env)->NewByteArray(env, length);
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, length, (const jbyte *)text);
    gus_llama_free_text(text);

done:
    if (c_template != NULL) (*env)->ReleaseStringUTFChars(env, template_override, c_template);
    if (owned != NULL) {
        for (jsize i = 0; i < count * 2; i++) free(owned[i]);
        free(owned);
    }
    free(messages);
    return result;
}

JNIEXPORT jstring JNICALL
Java_dev_iyscode_movil_gus_NativeLlama_nativeDescription(JNIEnv * env, jclass cls, jlong handle) {
    (void)cls;
    char * text = gus_llama_model_description((GUSLlamaContext *)(intptr_t)handle);
    if (text == NULL) return NULL;
    jstring out = (*env)->NewStringUTF(env, text);
    gus_llama_free_text(text);
    return out;
}

JNIEXPORT jint JNICALL
Java_dev_iyscode_movil_gus_NativeLlama_nativeInstallSignalTrap(JNIEnv * env, jclass cls, jstring path) {
    (void)cls;
    const char * c_path = (*env)->GetStringUTFChars(env, path, NULL);
    if (c_path == NULL) return -1;
    int rc = gus_signal_trap_install(c_path);
    (*env)->ReleaseStringUTFChars(env, path, c_path);
    return rc;
}
