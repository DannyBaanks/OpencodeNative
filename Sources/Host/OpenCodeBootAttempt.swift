import Foundation

/// Documenta el resultado de un **intento de arranque del TUI real de OpenCode**
/// dentro del sandbox de iOS por el runtime del experimento.
///
/// NO hay simulación: el "boot attempt" produce evidencia determinista derivada
/// de `CompatibilityReport` (capability matrix probada en runtime) y de la
/// inexistencia comprobada de APIs de PTY/Process en el SDK iOS. El
/// experimento captura el bloqueo **exacto** y lo expone en lugar de fingir
/// compatibilidad.
public struct OpenCodeBootAttempt: Sendable, Codable {
    public let timestamp: Date
    public let host: String
    public let canBoot: Bool
    public let firstBlocker: String?
    public let transcript: [String]
    public let compatibilityReport: CompatibilityReport

    public static func run(matrix: IOSCapabilityMatrix = .probeCurrent()) -> OpenCodeBootAttempt {
        let report = CompatibilityReport.generate(from: matrix)
        let lines = emitTranscript(report: report, matrix: matrix)
        return OpenCodeBootAttempt(
            timestamp: Date(),
            host: matrix.platform,
            canBoot: report.canOpenCodeBoot,
            firstBlocker: report.firstBlocker?.requirementLabel,
            transcript: lines,
            compatibilityReport: report
        )
    }

    private static func emitTranscript(report: CompatibilityReport, matrix: IOSCapabilityMatrix) -> [String] {
        var lines: [String] = []
        lines.append("opencode-boot> probing host: \(matrix.platform)")
        lines.append("opencode-boot> target: OpenCode TUI v\(OpenCodeRuntimeContract.openCodeVersion) (license \(OpenCodeRuntimeContract.openCodeLicense))")
        lines.append("opencode-boot> generating capability matrix …")
        for e in report.entries {
            let tag = "[\(e.verdict.rawValue.uppercased())]"
            lines.append("opencode-boot> \(tag.padding(toLength: 12, withPad: " ", startingAt: 0)) \(e.requirementLabel)")
        }
        lines.append("opencode-boot> reconciling …")
        if report.canOpenCodeBoot {
            lines.append("opencode-boot> OK — no hard blocker detected.")
        } else if let b = report.firstBlocker {
            lines.append("opencode-boot> BLOCKED at first hard blocker: \(b.requirementLabel)")
            lines.append("opencode-boot> evidence: \(b.evidence)")
            lines.append("opencode-boot> harness strategy: \(b.href ?? "n/a")")
            lines.append("opencode-boot> OpenCode TUI cannot initialize on this host. NOT simulated.")
        }
        lines.append("opencode-boot> exiting boot attempt.")
        return lines
    }
}
