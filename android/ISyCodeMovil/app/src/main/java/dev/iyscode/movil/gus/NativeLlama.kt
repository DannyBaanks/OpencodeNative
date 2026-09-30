package dev.iyscode.movil.gus

/** JNI bindings to the shared C bridge (Sources/Model/GUSLlamaBridge.c). */
object NativeLlama {
    private var loaded = false

    /** Loads libgus_jni.so once; false when the native library is unavailable (e.g. JVM tests). */
    @Synchronized
    fun ensureLoaded(): Boolean {
        if (loaded) return true
        loaded = runCatching { System.loadLibrary("gus_jni") }.isSuccess
        return loaded
    }

    @JvmStatic external fun nativeCreate(path: String, contextTokens: Int): Long
    @JvmStatic external fun nativeDestroy(handle: Long)
    @JvmStatic external fun nativeCancel(handle: Long)
    @JvmStatic external fun nativeGenerateChat(
        handle: Long,
        roles: Array<String>,
        contents: Array<ByteArray>,
        templateOverride: String?,
        maxTokens: Int,
        /** null = greedy; else [temperature, top_p, min_p, top_k, repeat_penalty, repeat_last_n]. */
        sampling: FloatArray?,
        stats: DoubleArray,
    ): ByteArray
    @JvmStatic external fun nativeDescription(handle: Long): String?
    @JvmStatic external fun nativeInstallSignalTrap(path: String): Int
}
