package dev.iyscode.movil.gus

import dev.iyscode.movil.diagnostics.FlightRecorder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.CancellationException

data class ChatMessage(val role: Role, val content: String) {
    enum class Role(val wire: String) { SYSTEM("system"), USER("user"), ASSISTANT("assistant") }
}

data class GenerationStats(
    val promptTokens: Int,
    val generatedTokens: Int,
    val prefillMs: Double,
    val generateMs: Double,
    val templateSource: TemplateSource,
    val stoppedAtEndOfTurn: Boolean,
) {
    enum class TemplateSource(val wire: String) { OVERRIDE("override"), EMBEDDED("embedded"), FALLBACK_CHATML("fallbackChatML") }

    val prefillTokensPerSecond: Double get() = if (prefillMs > 0) promptTokens * 1000.0 / prefillMs else 0.0
    val generationTokensPerSecond: Double get() = if (generateMs > 0) generatedTokens * 1000.0 / generateMs else 0.0

    companion object {
        /** Decodes the stats array filled by the JNI layer (see gus_jni.c). */
        fun fromNative(raw: DoubleArray) = GenerationStats(
            promptTokens = raw[2].toInt(),
            generatedTokens = raw[3].toInt(),
            prefillMs = raw[0],
            generateMs = raw[1],
            templateSource = when (raw[4].toInt()) {
                0 -> TemplateSource.OVERRIDE
                1 -> TemplateSource.EMBEDDED
                else -> TemplateSource.FALLBACK_CHATML
            },
            stoppedAtEndOfTurn = raw[5] != 0.0,
        )
    }
}

data class Generation(val text: String, val stats: GenerationStats)

/** A loaded local model. Implemented by [LlamaEngine]; faked in tests. */
interface LocalEngine {
    suspend fun load(model: GusModel, file: File, contextTokens: Int = 2048)
    suspend fun generate(messages: List<ChatMessage>, maxTokens: Int): Generation
    fun cancel()
    suspend fun unload()
    val loadedModelId: String?
}

/**
 * llama.cpp through JNI. A llama_context is mutable, so load/generate/unload
 * are serialized; cancel() is lock-free and stops the current generation.
 */
class LlamaEngine(private val recorder: FlightRecorder? = null) : LocalEngine {
    private val lane = Mutex()
    @Volatile private var handle = 0L
    @Volatile override var loadedModelId: String? = null
        private set
    private var templateOverride: String? = null

    override suspend fun load(model: GusModel, file: File, contextTokens: Int) = lane.withLock {
        if (loadedModelId == model.id && handle != 0L) return@withLock
        check(NativeLlama.ensureLoaded()) { "El motor local no está disponible en este dispositivo." }
        withContext(Dispatchers.IO) {
            if (handle != 0L) {
                NativeLlama.nativeDestroy(handle)
                handle = 0L
                loadedModelId = null
            }
            recorder?.beginPhase("model.load", model.id, mapOf("context" to contextTokens.toString()))
            val started = System.nanoTime()
            val created = runCatching { NativeLlama.nativeCreate(file.absolutePath, contextTokens) }
            recorder?.endPhase("model.load", mapOf(
                "ok" to created.isSuccess.toString(),
                "ms" to ((System.nanoTime() - started) / 1_000_000).toString(),
            ))
            handle = created.getOrThrow()
            loadedModelId = model.id
            templateOverride = model.chatTemplateOverride
        }
    }

    override suspend fun generate(messages: List<ChatMessage>, maxTokens: Int): Generation = lane.withLock {
        val current = handle
        check(current != 0L) { "El modelo GUS local no está cargado." }
        withContext(Dispatchers.IO) {
            // Sizes only: message text is never recorded.
            recorder?.beginPhase("generate", loadedModelId, mapOf(
                "messages" to messages.size.toString(),
                "chars" to messages.sumOf { it.content.toByteArray(Charsets.UTF_8).size }.toString(),
                "max_tokens" to maxTokens.toString(),
            ))
            val raw = DoubleArray(6)
            val result = runCatching {
                NativeLlama.nativeGenerateChat(
                    current,
                    messages.map { it.role.wire }.toTypedArray(),
                    messages.map { it.content.toByteArray(Charsets.UTF_8) }.toTypedArray(),
                    templateOverride,
                    maxTokens.coerceIn(1, 512),
                    raw,
                )
            }
            val stats = GenerationStats.fromNative(raw)
            recorder?.endPhase("generate", mapOf(
                "ok" to result.isSuccess.toString(),
                "prompt_tokens" to stats.promptTokens.toString(),
                "generated_tokens" to stats.generatedTokens.toString(),
                "gen_tok_s" to "%.1f".format(stats.generationTokensPerSecond),
                "template" to stats.templateSource.wire,
            ))
            val bytes = result.getOrElse { error ->
                if (error.message?.contains("cancel", ignoreCase = true) == true) throw CancellationException("Generation cancelled.")
                throw error
            }
            Generation(visibleAnswer(String(bytes, Charsets.UTF_8)), stats)
        }
    }

    override fun cancel() {
        val current = handle
        if (current != 0L) NativeLlama.nativeCancel(current)
    }

    override suspend fun unload() {
        cancel()
        lane.withLock {
            val current = handle
            handle = 0L
            loadedModelId = null
            if (current != 0L) {
                withContext(Dispatchers.IO) { NativeLlama.nativeDestroy(current) }
                recorder?.record("model.unload")
            }
        }
    }

    fun description(): String? = handle.takeIf { it != 0L }?.let { NativeLlama.nativeDescription(it) }

    companion object {
        /**
         * Reasoning models (Qwen3, SmolLM3, Nemotron) may emit a think block
         * first; only the answer is shown. Same rules as the iOS app.
         */
        fun visibleAnswer(raw: String): String {
            val open = raw.indexOf("<think>")
            if (open < 0) {
                val close = raw.indexOf("</think>")
                return if (close >= 0) raw.substring(close + "</think>".length).trim() else raw
            }
            val close = raw.indexOf("</think>", open + "<think>".length)
            if (close < 0) return raw.substring(0, open).trim()
            return (raw.substring(0, open) + raw.substring(close + "</think>".length)).trim()
        }
    }
}
