package dev.iyscode.movil

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import dev.iyscode.movil.bench.BenchmarkEnvironment
import dev.iyscode.movil.diagnostics.FlightRecorder
import dev.iyscode.movil.gus.DeviceBudget
import java.util.UUID

/** Android facts: memory, device, thermal state and system exit reasons. */
class AndroidPlatform(private val context: Context) : BenchmarkEnvironment {
    private val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    private val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager

    private fun memoryInfo() = ActivityManager.MemoryInfo().also { activityManager.getMemoryInfo(it) }

    /** Proportional set size of this process (includes touched pages of the mmapped model). */
    override fun footprintBytes(): Long = Debug.getPss() * 1024

    fun budget(): DeviceBudget {
        val info = memoryInfo()
        return DeviceBudget.from(info.totalMem, info.availMem, info.threshold, footprintBytes())
    }

    fun memorySample(): FlightRecorder.MemorySample {
        val info = memoryInfo()
        return FlightRecorder.MemorySample(footprintBytes(), info.availMem)
    }

    override val appVersion: String by lazy {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        @Suppress("DEPRECATION")
        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        "${info.versionName} ($code)"
    }
    override val deviceModel: String = "${Build.MANUFACTURER} ${Build.MODEL}".trim()
    override val osVersion: String = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"
    override val ramBytes: Long by lazy { memoryInfo().totalMem }
    override fun appMemoryLimitBytes(): Long = budget().appMemoryLimit
    override fun powerSaveMode(): Boolean = powerManager.isPowerSaveMode
    override fun now(): String = FlightRecorder.now()

    override fun thermalState(): String {
        if (Build.VERSION.SDK_INT < 29) return "unknown"
        return when (powerManager.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE, PowerManager.THERMAL_STATUS_LIGHT -> "nominal"
            PowerManager.THERMAL_STATUS_MODERATE -> "fair"
            PowerManager.THERMAL_STATUS_SEVERE -> "serious"
            else -> "critical"
        }
    }

    /**
     * Turns new system exit records (Android 11+) into crash reports. This is
     * Android's confirmation of *why* the process ended: low memory, native
     * crash, ANR… The last seen timestamp is kept so each exit is reported once.
     */
    fun collectSystemExits(recorder: FlightRecorder) {
        if (Build.VERSION.SDK_INT < 30) return
        val prefs = context.getSharedPreferences("diagnostics", Context.MODE_PRIVATE)
        val lastSeen = prefs.getLong("exit_info_seen", 0L)
        val exits = runCatching { activityManager.getHistoricalProcessExitReasons(context.packageName, 0, 8) }
            .getOrDefault(emptyList())
        var newest = lastSeen
        for (exit in exits.filter { it.timestamp > lastSeen }) {
            newest = maxOf(newest, exit.timestamp)
            val (label, cause) = describe(exit) ?: continue
            val trace = if (exit.reason == ApplicationExitInfo.REASON_CRASH_NATIVE || exit.reason == ApplicationExitInfo.REASON_ANR) {
                runCatching { exit.traceInputStream?.use { it.readNBytesCompat(16 * 1024).toString(Charsets.UTF_8) } }.getOrNull()
            } else null
            val details = buildString {
                append("reason=${exit.reason} status=${exit.status} importance=${exit.importance}")
                append(" pss=${exit.pss}KB rss=${exit.rss}KB")
                exit.description?.let { append("\n").append(it) }
                trace?.let { append("\n\n").append(it) }
            }
            recorder.save(FlightRecorder.CrashReport(
                id = UUID.randomUUID().toString(),
                kind = FlightRecorder.CrashReport.Kind.SYSTEM_EXIT_INFO,
                createdAt = FlightRecorder.now(),
                summary = "Android: $label",
                likelyCause = cause + " Memoria del proceso al salir: ${FlightRecorder.formatBytes(exit.pss * 1024)}.",
                systemDiagnostic = details,
            ))
        }
        if (newest > lastSeen) prefs.edit().putLong("exit_info_seen", newest).apply()
    }

    private fun describe(exit: ApplicationExitInfo): Pair<String, String>? = when (exit.reason) {
        ApplicationExitInfo.REASON_LOW_MEMORY -> "cerrada por falta de memoria" to
            "Confirmado por Android: el sistema cerró la app para recuperar memoria. Usa un modelo más pequeño o cierra otras apps."
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "fallo en código nativo" to
            "Un error en llama.cpp o en el bridge nativo. El detalle incluye la traza del sistema."
        ApplicationExitInfo.REASON_CRASH -> "excepción no controlada" to "Un error de la app en Kotlin."
        ApplicationExitInfo.REASON_ANR -> "la app dejó de responder (ANR)" to
            "El hilo principal quedó bloqueado demasiado tiempo."
        ApplicationExitInfo.REASON_SIGNALED -> "terminada por una señal del sistema" to
            "Android envió una señal al proceso (a menudo por memoria o por el sistema)."
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "uso excesivo de recursos" to
            "Android detuvo la app por consumir demasiados recursos."
        else -> null  // user request, normal exit, updates… are not failures
    }

    private fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (out.size() < limit) {
            val n = read(buffer, 0, minOf(buffer.size, limit - out.size()))
            if (n < 0) break
            out.write(buffer, 0, n)
        }
        return out.toByteArray()
    }
}
