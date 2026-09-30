import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit

/// Receives Apple's own diagnostics: crash call stacks (MXCrashDiagnostic) and
/// daily exit-reason counters (MXAppExitMetric), which are the only way to
/// *confirm* a memory-limit (jetsam) termination. Delivery is up to iOS:
/// diagnostics usually arrive on the next launch, metrics about once a day.
public final class GUSMetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = GUSMetricKitCollector()
    private var registered = false

    public func register() {
        guard !registered else { return }
        registered = true
        MXMetricManager.shared.add(self)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let signal = crash.signal?.int32Value
                let exception = crash.exceptionType?.intValue
                let reason = crash.terminationReason ?? "sin motivo"
                let summary = "Crash reportado por iOS · \(signal.map(GUSFlightRecorder.signalName) ?? "excepción \(exception ?? -1)")"
                let json = String(data: crash.jsonRepresentation(), encoding: .utf8)
                GUSFlightRecorder.shared.save(.init(
                    id: UUID().uuidString, kind: .metricKitCrash, createdAt: payload.timeStampEnd,
                    summary: summary, likelyCause: "Motivo de iOS: \(reason). El JSON incluye la pila de llamadas simbolizable.",
                    marker: nil, breadcrumbs: [], appleDiagnostic: json))
            }
        }
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let fg = exits.foregroundExitData
            let bg = exits.backgroundExitData
            let memoryFG = fg.cumulativeMemoryResourceLimitExitCount
            let abnormalFG = fg.cumulativeAbnormalExitCount
            let watchdogFG = fg.cumulativeAppWatchdogExitCount
            guard memoryFG + abnormalFG + watchdogFG + bg.cumulativeMemoryResourceLimitExitCount > 0 else { continue }
            let summary = "iOS: \(memoryFG) cierre(s) por memoria en primer plano, \(abnormalFG) anómalo(s), \(watchdogFG) por watchdog"
            let cause = memoryFG > 0
                ? "Confirmado por iOS: la app superó su límite de memoria. Usa un modelo más pequeño o contexto 2K."
                : "Resumen diario de salidas de la app según iOS."
            GUSFlightRecorder.shared.save(.init(
                id: UUID().uuidString, kind: .metricKitExits, createdAt: payload.timeStampEnd,
                summary: summary, likelyCause: cause, marker: nil, breadcrumbs: [],
                appleDiagnostic: String(data: exits.jsonRepresentation(), encoding: .utf8)))
        }
    }
}
#endif
