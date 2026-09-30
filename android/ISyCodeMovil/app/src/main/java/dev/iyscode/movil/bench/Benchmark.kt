package dev.iyscode.movil.bench

import dev.iyscode.movil.gus.ChatMessage
import dev.iyscode.movil.gus.ChatMessage.Role
import dev.iyscode.movil.gus.GusModel
import dev.iyscode.movil.gus.LocalEngine
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import java.io.File
import java.util.UUID

/**
 * On-device benchmark, protocol v1: the same fixed tasks, limits and JSON
 * schema as the iOS app (GUSBenchmark.swift), so results from Android and
 * iPhone land in the same docs/BENCHMARKS.md table.
 */
@Serializable
data class BenchmarkReport(
    val schema: String = SCHEMA,
    @SerialName("protocol") val protocolVersion: Int = Benchmark.PROTOCOL_VERSION,
    @SerialName("run_id") val runId: String,
    val status: Status,
    @SerialName("created_at") val createdAt: String,
    @SerialName("app_version") val appVersion: String,
    @SerialName("llama_cpp_commit") val llamaCppCommit: String,
    val device: Device,
    val model: Model,
    @SerialName("footprint_before_bytes") val footprintBeforeBytes: Long,
    @SerialName("peak_footprint_bytes") val peakFootprintBytes: Long,
    @SerialName("load_ms") val loadMs: Double? = null,
    @SerialName("thermal_start") val thermalStart: String,
    @SerialName("thermal_end") val thermalEnd: String? = null,
    val tasks: List<TaskResult> = emptyList(),
    @SerialName("stopped_during") val stoppedDuring: String? = null,
    val error: String? = null,
) {
    @Serializable
    enum class Status { @SerialName("completed") COMPLETED, @SerialName("failed") FAILED, @SerialName("killed") KILLED }

    @Serializable
    data class Device(
        val platform: String = "android",
        val model: String,
        val os: String,
        @SerialName("ram_bytes") val ramBytes: Long,
        @SerialName("app_memory_limit_bytes") val appMemoryLimitBytes: Long,
        @SerialName("low_power_mode") val lowPowerMode: Boolean,
    )

    @Serializable
    data class Model(
        val id: String,
        val sha256: String,
        @SerialName("byte_count") val byteCount: Long,
        @SerialName("context_tokens") val contextTokens: Int,
    )

    @Serializable
    data class TaskResult(
        val id: String,
        @SerialName("prompt_tokens") val promptTokens: Int,
        @SerialName("generated_tokens") val generatedTokens: Int,
        @SerialName("prefill_tok_s") val prefillTokS: Double,
        @SerialName("gen_tok_s") val genTokS: Double,
        val template: String,
        @SerialName("stopped_at_eot") val stoppedAtEot: Boolean,
        val passed: Boolean,
    )

    fun json(pretty: Boolean = true): String = (if (pretty) Benchmark.prettyJson else Benchmark.json).encodeToString(this)

    companion object {
        const val SCHEMA = "isycode.gus.benchmark/1"
    }
}

/** Device facts the benchmark needs; supplied by the Android layer (fake in tests). */
interface BenchmarkEnvironment {
    val appVersion: String
    val deviceModel: String
    val osVersion: String
    val ramBytes: Long
    fun appMemoryLimitBytes(): Long
    fun footprintBytes(): Long
    fun thermalState(): String
    fun powerSaveMode(): Boolean
    fun now(): String
}

object Benchmark {
    const val PROTOCOL_VERSION = 1
    const val CONTEXT_TOKENS = 2048

    val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    val prettyJson = Json { encodeDefaults = true; prettyPrint = true }

    class Spec(val id: String, val messages: List<ChatMessage>, val maxTokens: Int, val check: (String) -> Boolean)

    /** ~900 tokens of deterministic filler for prefill timing (same text as iOS). */
    val longPassage: String by lazy {
        val sentences = listOf(
            "The harbor town woke early, and the fishermen checked their nets before the tide turned.",
            "A lighthouse keeper wrote the weather in a ledger every hour, as his father had done.",
            "Merchants arrived with salt, rope and lamp oil, and left with dried fish and wool.",
            "In winter the storms closed the road over the hills for weeks at a time.",
            "Children learned to read the sky, the color of the water and the flight of the gulls.",
            "When the railway finally came, the town grew, but the harbor stayed its heart.",
        )
        (0 until 6).joinToString("\n") { round -> sentences.joinToString(" ") { "$it (${round + 1})" } }
    }

    /** Fixed tasks. Must match GUSBenchmark.tasks on iOS; changing any requires a new protocol version. */
    val tasks: List<Spec> = listOf(
        Spec("short-answer",
            listOf(ChatMessage(Role.SYSTEM, "You are a concise assistant."),
                ChatMessage(Role.USER, "What is the capital of France? Answer with one word.")),
            16) { it.contains("paris", ignoreCase = true) },
        Spec("json-object",
            listOf(ChatMessage(Role.SYSTEM, "You reply with JSON only, no prose and no markdown."),
                ChatMessage(Role.USER, "Return a JSON object with keys \"city\" and \"country\" for the capital of Japan.")),
            64) { isJsonObject(it, listOf("city", "country")) },
        Spec("long-prefill",
            listOf(ChatMessage(Role.SYSTEM, "You are a concise assistant."),
                ChatMessage(Role.USER, longPassage + "\n\nSummarize the passage above in one sentence.")),
            48) { it.isNotBlank() },
        Spec("sustained-generation",
            listOf(ChatMessage(Role.SYSTEM, "You follow instructions exactly."),
                ChatMessage(Role.USER, "Count from 1 to 60, separated by single spaces. Output only the numbers.")),
            160) { it.contains("10 11 12") },
    )

    fun isJsonObject(text: String, requiredKeys: List<String>): Boolean {
        var candidate = text.trim()
        if (candidate.startsWith("```")) {
            candidate = candidate.replace("```json", "").replace("```", "").trim()
        }
        val obj = runCatching { json.parseToJsonElement(candidate).jsonObject }.getOrNull() ?: return false
        return requiredKeys.all { it in (obj as JsonObject) }
    }

    fun rounded(value: Double) = Math.round(value * 100) / 100.0

    /** A pending file left behind means Android killed the app mid-run. */
    fun takeKilledRun(pending: File): BenchmarkReport? {
        if (!pending.exists()) return null
        val text = runCatching { pending.readText() }.getOrNull()
        pending.delete()
        val report = text?.let { runCatching { json.decodeFromString<BenchmarkReport>(it) }.getOrNull() } ?: return null
        return report.copy(
            status = BenchmarkReport.Status.KILLED,
            error = "Android terminó la app durante ${report.stoppedDuring ?: "el benchmark"} (sin señal capturable; típicamente falta de memoria).",
        )
    }

    /**
     * Runs the protocol with [engine]. The report is written to [pending]
     * before each step so a kill is reported on the next launch.
     */
    suspend fun run(
        model: GusModel,
        modelFile: File,
        engine: LocalEngine,
        env: BenchmarkEnvironment,
        llamaCppCommit: String,
        pending: File,
        progress: (String) -> Unit = {},
    ): BenchmarkReport = coroutineScope {
        var peak = env.footprintBytes()
        val sampler = launch {
            while (isActive) {
                peak = maxOf(peak, env.footprintBytes())
                delay(200)
            }
        }
        var report = BenchmarkReport(
            runId = UUID.randomUUID().toString(), status = BenchmarkReport.Status.FAILED, createdAt = env.now(),
            appVersion = env.appVersion, llamaCppCommit = llamaCppCommit,
            device = BenchmarkReport.Device(model = env.deviceModel, os = env.osVersion, ramBytes = env.ramBytes,
                appMemoryLimitBytes = env.appMemoryLimitBytes(), lowPowerMode = env.powerSaveMode()),
            model = BenchmarkReport.Model(model.id, model.sha256, model.byteCount, CONTEXT_TOKENS),
            footprintBeforeBytes = peak, peakFootprintBytes = peak, thermalStart = env.thermalState(),
            stoppedDuring = "load",
        )
        fun persist() { runCatching { pending.parentFile?.mkdirs(); pending.writeText(json.encodeToString(report)) } }
        fun finish(r: BenchmarkReport): BenchmarkReport {
            sampler.cancel()
            pending.delete()
            return r.copy(peakFootprintBytes = maxOf(peak, env.footprintBytes()), thermalEnd = env.thermalState())
        }
        persist()
        try {
            progress("Cargando modelo…")
            val started = System.nanoTime()
            try {
                engine.load(model, modelFile, CONTEXT_TOKENS)
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                return@coroutineScope finish(report.copy(error = e.message ?: "No se pudo cargar el modelo."))
            }
            report = report.copy(loadMs = (System.nanoTime() - started) / 1e6)
            for ((index, spec) in tasks.withIndex()) {
                report = report.copy(stoppedDuring = "task:${spec.id}", peakFootprintBytes = peak)
                persist()
                progress("Tarea ${index + 1}/${tasks.size}: ${spec.id}")
                val generation = try {
                    engine.generate(spec.messages, spec.maxTokens)
                } catch (e: Exception) {
                    if (e is kotlinx.coroutines.CancellationException) throw e
                    return@coroutineScope finish(report.copy(error = e.message ?: "La generación falló."))
                }
                val s = generation.stats
                report = report.copy(tasks = report.tasks + BenchmarkReport.TaskResult(
                    id = spec.id, promptTokens = s.promptTokens, generatedTokens = s.generatedTokens,
                    prefillTokS = rounded(s.prefillTokensPerSecond), genTokS = rounded(s.generationTokensPerSecond),
                    template = s.templateSource.wire, stoppedAtEot = s.stoppedAtEndOfTurn, passed = spec.check(generation.text),
                ))
            }
            finish(report.copy(status = BenchmarkReport.Status.COMPLETED, stoppedDuring = null))
        } finally {
            sampler.cancel()
            runCatching { engine.unload() }
        }
    }
}
