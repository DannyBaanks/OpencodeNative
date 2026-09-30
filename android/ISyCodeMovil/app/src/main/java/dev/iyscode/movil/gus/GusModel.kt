package dev.iyscode.movil.gus

/**
 * Provenance for a GGUF artifact approved for GUS local use.
 *
 * The approved set lives in Catalog/models.json and is compiled into
 * [GusCatalog] (and into the iOS app); it is never fetched at runtime, because
 * the pinned SHA-256 is what authorizes a file to be loaded by llama.cpp.
 */
data class GusModel(
    val id: String,
    val name: String,
    val repository: String,
    val filename: String,
    val revision: String,
    val sourceUrl: String,
    val byteCount: Long,
    val sha256: String,
    val licenseName: String,
    val licenseUrl: String,
    val attribution: String,
    val family: String,
    val vendor: String,
    val parameterLabel: String,
    val commercialUse: Boolean,
    /** A builtin llama.cpp template name; null uses the template embedded in the GGUF. */
    val chatTemplateOverride: String?,
    /** Experimental models are hidden unless the user opts in and accepts the risk. */
    val isExperimental: Boolean,
    val evidence: Evidence,
    val architecture: String?,
    /** f16 K+V bytes per context token, read from the GGUF header by the pin workflow. */
    val kvBytesPerToken: Long?,
    val nativeContextLength: Int?,
    /** System directive that turns off `<think>` for reasoning models in chat. */
    val thinkingOffDirective: String? = null,
) {
    enum class Evidence { UNMEASURED, DESKTOP_SMOKE, DEVICE_MEASURED }

    /** The chat system prompt for this model: reasoning models get their thinking-off directive. */
    fun chatSystemPrompt(base: String): String = thinkingOffDirective?.let { "$base\n\n$it" } ?: base

    /** Short display name without the quantization suffix. */
    val shortName: String get() = name.substringBefore(" ·")

    /**
     * Conservative estimate of resident memory once loaded with [contextTokens].
     * Same formula as the iOS app (GUSModelManifest.estimatedPeakBytes).
     */
    fun estimatedPeakBytes(contextTokens: Int): Long {
        val kvPerToken = kvBytesPerToken ?: (256L * 1024)
        val kv = kvPerToken * contextTokens
        val computeAndRuntime = 160L * 1024 * 1024 + byteCount / 10
        return byteCount + kv + computeAndRuntime
    }
}
