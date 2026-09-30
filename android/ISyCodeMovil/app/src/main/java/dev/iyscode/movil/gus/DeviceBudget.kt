package dev.iyscode.movil.gus

/**
 * What this device can afford for a local model, measured at runtime.
 *
 * Android has no per-app jetsam limit like iOS; the low-memory killer acts on
 * the whole system. The closest equivalent of "what the app may still use" is
 * the memory currently available to the system plus what the app already
 * holds, minus the threshold at which Android starts killing processes.
 */
data class DeviceBudget(
    val physicalMemory: Long,
    val appMemoryLimit: Long,
    val currentFootprint: Long,
) {
    enum class Fit { COMFORTABLE, TIGHT, UNLIKELY }

    fun fit(model: GusModel, contextTokens: Int = 2048): Fit =
        classify(model.estimatedPeakBytes(contextTokens), appMemoryLimit)

    companion object {
        /** Same thresholds as iOS: ≤70 % comfortable, ≤90 % tight. */
        fun classify(peak: Long, limit: Long): Fit {
            if (limit <= 0) return Fit.UNLIKELY
            val ratio = peak.toDouble() / limit.toDouble()
            return when {
                ratio <= 0.70 -> Fit.COMFORTABLE
                ratio <= 0.90 -> Fit.TIGHT
                else -> Fit.UNLIKELY
            }
        }

        /** Builds a budget from ActivityManager.MemoryInfo numbers (pure, testable). */
        fun from(totalMem: Long, availMem: Long, threshold: Long, footprint: Long): DeviceBudget {
            val usable = (availMem - threshold).coerceAtLeast(0) + footprint
            return DeviceBudget(physicalMemory = totalMem, appMemoryLimit = usable, currentFootprint = footprint)
        }
    }
}
