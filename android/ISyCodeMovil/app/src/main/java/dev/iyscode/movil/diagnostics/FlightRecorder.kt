package dev.iyscode.movil.diagnostics

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/**
 * Crash forensics for local models (same design as the iOS app).
 *
 * Android's low-memory killer ends a process with SIGKILL, which no code can
 * observe. So the recorder writes *before* risky work: a small session marker
 * (what the app is doing right now) and an append-only breadcrumb log. If the
 * next launch finds the marker still in a risky phase, the previous run died
 * there. Fatal native signals are recorded by the shared async-signal-safe trap
 * (Sources/Diagnostics/GUSSignalTrap.c) and ApplicationExitInfo later adds
 * Android's own exit reason.
 *
 * Privacy: only structural facts (model id, sizes, token counts, timings,
 * memory). Prompt and answer text are never written.
 */
class FlightRecorder(
    private val directory: File,
    private val memoryProbe: () -> MemorySample = { MemorySample.jvm() },
) {
    data class MemorySample(val footprintBytes: Long, val availableBytes: Long) {
        companion object {
            fun jvm(): MemorySample {
                val rt = Runtime.getRuntime()
                return MemorySample(rt.totalMemory() - rt.freeMemory(), rt.maxMemory() - (rt.totalMemory() - rt.freeMemory()))
            }
        }
    }

    @Serializable
    data class Breadcrumb(
        val time: String,
        val event: String,
        val fields: Map<String, String> = emptyMap(),
        val footprintBytes: Long = 0,
        val availableBytes: Long = 0,
    )

    @Serializable
    data class SessionMarker(
        val sessionId: String,
        val launchedAt: String,
        val appVersion: String,
        val osVersion: String,
        val deviceModel: String,
        val physicalMemory: Long,
        var phase: String,
        var phaseStartedAt: String,
        var modelId: String? = null,
        var inForeground: Boolean = true,
        var peakFootprintBytes: Long = 0,
    )

    @Serializable
    data class CrashReport(
        val id: String,
        val kind: Kind,
        val createdAt: String,
        /** One line a person can read: where and why. */
        val summary: String,
        val likelyCause: String,
        val marker: SessionMarker? = null,
        val breadcrumbs: List<Breadcrumb> = emptyList(),
        /** Raw Android diagnostic (ApplicationExitInfo description / trace) when available. */
        val systemDiagnostic: String? = null,
    ) {
        @Serializable
        enum class Kind { UNCLEAN_EXIT, FATAL_SIGNAL, UNCAUGHT_EXCEPTION, SYSTEM_EXIT_INFO }
    }

    private val lock = Any()
    private var marker: SessionMarker? = null
    private var started = false
    private var breadcrumbStream: FileOutputStream? = null

    /** Reports produced at this launch about the previous run. */
    @Volatile var previousRunReports: List<CrashReport> = emptyList()
        private set

    private val markerFile get() = File(directory, "session.json")
    private val breadcrumbsFile get() = File(directory, "breadcrumbs.jsonl")
    val signalFile get() = File(directory, "signal.txt")
    private val reportsDir get() = File(directory, "reports")

    /** Call once at launch, before any model work. */
    fun start(appVersion: String, osVersion: String, deviceModel: String, physicalMemory: Long): List<CrashReport> = synchronized(lock) {
        if (started) return@synchronized emptyList()
        started = true
        reportsDir.mkdirs()
        val previousMarker = runCatching { json.decodeFromString<SessionMarker>(markerFile.readText()) }.getOrNull()
        val previousSignal = runCatching { signalFile.readText().trim() }.getOrNull()
        val created = listOfNotNull(diagnose(previousMarker, previousSignal, readBreadcrumbs(40), now()))
        created.forEach(::save)
        signalFile.delete()
        trimBreadcrumbs()

        val now = now()
        marker = SessionMarker(
            sessionId = UUID.randomUUID().toString(), launchedAt = now, appVersion = appVersion,
            osVersion = osVersion, deviceModel = deviceModel, physicalMemory = physicalMemory,
            phase = "launch", phaseStartedAt = now, peakFootprintBytes = memoryProbe().footprintBytes,
        )
        writeMarker()
        breadcrumbStream = FileOutputStream(breadcrumbsFile, true)
        appendLocked("app.launch", mapOf("version" to appVersion, "os" to osVersion, "device" to deviceModel), sync = true)
        previousRunReports = created
        created
    }

    fun markBackground() { setForeground(false) }
    fun markForeground() { setForeground(true) }

    private fun setForeground(value: Boolean): Unit = synchronized(lock) {
        val current = marker ?: return@synchronized
        if (current.inForeground == value) return@synchronized
        current.inForeground = value
        writeMarker()
        appendLocked(if (value) "app.foreground" else "app.background", emptyMap(), sync = false)
    }

    /** Records the start of a risky phase; the marker is flushed before the work starts. */
    fun beginPhase(phase: String, modelId: String?, fields: Map<String, String> = emptyMap()) {
        updatePhase(phase, modelId)
        record("$phase.begin", fields + ("model" to (modelId ?: "-")), sync = true)
    }

    fun endPhase(phase: String, fields: Map<String, String> = emptyMap()) {
        record("$phase.end", fields)
        updatePhase("idle", marker?.modelId)
    }

    fun record(event: String, fields: Map<String, String> = emptyMap(), sync: Boolean = false): Unit = synchronized(lock) {
        appendLocked(event, fields, sync)
    }

    private fun appendLocked(event: String, fields: Map<String, String>, sync: Boolean) {
        val sample = memoryProbe()
        val crumb = Breadcrumb(now(), event, fields, sample.footprintBytes, sample.availableBytes)
        val stream = breadcrumbStream ?: return
        runCatching {
            stream.write((json.encodeToString(crumb) + "\n").toByteArray(Charsets.UTF_8))
            if (sync) stream.fd.sync()
        }
        marker?.let { if (sample.footprintBytes > it.peakFootprintBytes) it.peakFootprintBytes = sample.footprintBytes }
    }

    private fun updatePhase(phase: String, modelId: String?): Unit = synchronized(lock) {
        val current = marker ?: return@synchronized
        current.phase = phase
        current.phaseStartedAt = now()
        current.modelId = modelId
        current.peakFootprintBytes = maxOf(current.peakFootprintBytes, memoryProbe().footprintBytes)
        writeMarker()
    }

    private fun writeMarker() {
        val current = marker ?: return
        runCatching {
            directory.mkdirs()
            val tmp = File(directory, "session.json.tmp")
            tmp.writeText(json.encodeToString(current))
            tmp.renameTo(markerFile)
        }
    }

    // Reports

    fun save(report: CrashReport) {
        reportsDir.mkdirs()
        runCatching { File(reportsDir, "${report.id}.json").writeText(json.encodeToString(report)) }
        val all = reports()
        all.drop(REPORT_LIMIT).forEach { File(reportsDir, "${it.id}.json").delete() }
    }

    fun reports(): List<CrashReport> =
        (reportsDir.listFiles { f -> f.extension == "json" } ?: emptyArray())
            .mapNotNull { runCatching { json.decodeFromString<CrashReport>(it.readText()) }.getOrNull() }
            .sortedByDescending { it.createdAt }

    fun deleteAllReports() {
        reportsDir.deleteRecursively()
        reportsDir.mkdirs()
    }

    /** Pretty JSON for sharing (issue attachment); contains no prompt text. */
    fun exportJson(report: CrashReport): String = prettyJson.encodeToString(report)

    fun recentBreadcrumbs(limit: Int = 40): List<Breadcrumb> = synchronized(lock) {
        runCatching { breadcrumbStream?.fd?.sync() }
        readBreadcrumbs(limit)
    }

    private fun readBreadcrumbs(limit: Int): List<Breadcrumb> =
        runCatching { breadcrumbsFile.readLines() }.getOrDefault(emptyList())
            .takeLast(limit)
            .mapNotNull { runCatching { json.decodeFromString<Breadcrumb>(it) }.getOrNull() }

    private fun trimBreadcrumbs() {
        val file = breadcrumbsFile
        if (!file.exists() || file.length() <= BREADCRUMB_LIMIT_BYTES) return
        val lines = file.readLines()
        var kept = 0L
        val tail = lines.asReversed().takeWhile { kept += it.length + 1; kept <= BREADCRUMB_LIMIT_BYTES / 2 }.asReversed()
        file.writeText(tail.joinToString("\n", postfix = "\n"))
    }

    companion object {
        const val BREADCRUMB_LIMIT_BYTES = 256L * 1024
        const val REPORT_LIMIT = 50

        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        private val prettyJson = Json { prettyPrint = true; encodeDefaults = true }

        fun now(): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date())

        /** Pure diagnosis of how the previous run ended (unit-tested). */
        fun diagnose(marker: SessionMarker?, signalLine: String?, breadcrumbs: List<Breadcrumb>, at: String): CrashReport? {
            marker ?: return null
            val signal = signalLine?.takeIf { it.startsWith("signal=") }?.removePrefix("signal=")?.toIntOrNull()
            // A backgrounded or idle app killed by Android is normal housekeeping.
            val risky = marker.phase != "idle" && marker.phase != "launch"
            if (signal == null && !(marker.inForeground && risky)) return null

            val model = marker.modelId ?: "sin modelo"
            val limitHint = breadcrumbs.lastOrNull()?.let {
                " Última medición: ${formatBytes(it.footprintBytes)} en uso, ${formatBytes(it.availableBytes)} disponibles."
            } ?: ""
            val (kind, summary, cause) = if (signal != null) {
                Triple(
                    CrashReport.Kind.FATAL_SIGNAL,
                    "${signalName(signal)} durante ${phaseLabel(marker.phase)} · $model",
                    if (signal == SIGABRT) "Aborto explícito: normalmente una aserción de llama.cpp (GGML_ASSERT)."
                    else "Acceso inválido a memoria u operación ilegal en código nativo.",
                )
            } else {
                val memoryPhase = listOf("model.load", "generate", "benchmark").any { marker.phase.startsWith(it) }
                Triple(
                    CrashReport.Kind.UNCLEAN_EXIT,
                    "La app terminó durante ${phaseLabel(marker.phase)} · $model",
                    if (memoryPhase) "Probablemente Android la cerró por falta de memoria.$limitHint Android confirmará el motivo al volver a abrir la app si lo registró."
                    else "Cierre no limpio sin señal capturada (memoria, sistema o cierre forzado).$limitHint",
                )
            }
            return CrashReport(UUID.randomUUID().toString(), kind, at, summary, cause, marker, breadcrumbs)
        }

        fun phaseLabel(phase: String) = when (phase) {
            "model.load" -> "la carga del modelo"
            "generate" -> "la generación"
            "benchmark" -> "el benchmark"
            else -> phase
        }

        const val SIGABRT = 6
        fun signalName(signal: Int) = when (signal) {
            6 -> "SIGABRT"; 11 -> "SIGSEGV"; 7 -> "SIGBUS"; 4 -> "SIGILL"; 8 -> "SIGFPE"; 5 -> "SIGTRAP"
            else -> "señal $signal"
        }

        fun formatBytes(bytes: Long): String {
            val units = listOf("B", "KB", "MB", "GB")
            var value = bytes.toDouble()
            var unit = 0
            while (value >= 1024 && unit < units.lastIndex) { value /= 1024; unit++ }
            return if (unit == 0) "$bytes B" else String.format(Locale.US, "%.1f %s", value, units[unit])
        }
    }
}
