import Foundation

/// Reconcilia el contrato de OpenCode (`OpenCodeRuntimeContract.Requirement`)
/// con la matriz de capabilities iOS disponible (`IOSCapabilityMatrix`).
///
/// Para cada capability requerida se emite un veredicto:
/// `compatible`        — iOS la provee tal cual.
/// `partial`           — iOS provee una alternativa nativa distinta; no es drop-in.
/// `unsupported`       — iOS no la provee.
/// `uncharted`         — No se pudo determinar (e.g. host no iOS).
public struct CompatibilityReport: Sendable, Codable {
    public struct Entry: Sendable, Codable, Identifiable {
        public let id: String                  // = requirement.rawValue
        public let requirement: String
        public let requirementLabel: String
        public let evidence: String             // citation from OpenCode repo
        public let verdict: Verdict
        public let href: String?               // optional harness strategy

        public enum Verdict: String, Codable, Sendable {
            case compatible
            case partial
            case unsupported
            case uncharted
        }
    }

    public let isIOSHost: Bool
    public let entries: [Entry]

    /// Veredicto consolidado: el TUI real de OpenCode **arranca** solo si
    /// todas las capabilities marcadas como HARD BLOCKER están `compatible`.
    /// HARD BLOCKERS aquí: `nativeExecutable`, `bunRuntime`, `ptyTTY`, `spawnExec`, `treeSitterNative` (sin éstas no arranca).
    public let canOpenCodeBoot: Bool
    public let firstBlocker: Entry?

    public static func generate(from matrix: IOSCapabilityMatrix) -> CompatibilityReport {
        if !matrix.isIOS {
            let entries = OpenCodeRuntimeContract.Requirement.allCases.map { req in
                Entry(
                    id: req.rawValue,
                    requirement: req.rawValue,
                    requirementLabel: req.label,
                    evidence: req.evidence,
                    verdict: .uncharted,
                    href: "Host no iOS — probe ejecutar en dispositivo"
                )
            }
            return CompatibilityReport(isIOSHost: false, entries: entries, canOpenCodeBoot: false, firstBlocker: nil)
        }
        var entries: [Entry] = []
        var firstHardBlock: Entry?
        for req in OpenCodeRuntimeContract.Requirement.allCases {
            let verdict = verdict(for: req, from: matrix)
            let e = Entry(
                id: req.rawValue,
                requirement: req.rawValue,
                requirementLabel: req.label,
                evidence: req.evidence,
                verdict: verdict,
                href: Self.harnessHint(req, verdict, matrix)
            )
            entries.append(e)
            let isHard = Self.hardBlockers.contains(req)
            // Solo declaramos bloqueo cuando hay evidencia .unsupported (no `.uncharted`).
            if isHard && verdict == .unsupported && firstHardBlock == nil {
                firstHardBlock = e
            }
        }
        let boot = (firstHardBlock == nil)
        return CompatibilityReport(
            isIOSHost: true,
            entries: entries,
            canOpenCodeBoot: boot,
            firstBlocker: firstHardBlock
        )
    }

    private static let hardBlockers: Set<OpenCodeRuntimeContract.Requirement> = [
        .nativeExecutable, .bunRuntime, .ptyTTY, .spawnExec
    ]

    private static func verdict(for req: OpenCodeRuntimeContract.Requirement, from m: IOSCapabilityMatrix) -> Entry.Verdict {
        switch req {
        case .nativeExecutable:
            // No hay binario iOS distribuido; un binario darwin-arm64 no corre en iOS.
            return .unsupported
        case .bunRuntime:
            return m.bunRuntime.availability == .available ? .compatible
                 : (m.javaScriptEngine.availability == .available ? .partial : .unsupported)
        case .ptyTTY:
            return m.ptyTTY.availability == .available ? .compatible : .unsupported
        case .spawnExec:
            return m.processExec.availability == .available ? .compatible : .unsupported
        case .nodeFsAndWatch:
            return m.sandboxFS.availability == .available ? .partial : .unsupported
        case .sqliteBun:
            return m.sqlite.availability == .available ? .partial : .unsupported
        case .treeSitterNative:
            return m.treeSitterNative.availability == .available ? .compatible : .unsupported
        case .networkTLSWS:
            return (m.networkTLS.availability == .available && m.webSocket.availability == .available)
                 ? .compatible : .unsupported
        case .posixEnv:
            return m.posixEnv.availability == .available ? .compatible : .unsupported
        }
    }

    private static func harnessHint(_ req: OpenCodeRuntimeContract.Requirement, _ verdict: Entry.Verdict, _ m: IOSCapabilityMatrix) -> String? {
        switch (req, verdict) {
        case (.nativeExecutable, .unsupported):
            return "Sin binario iOS en releases OpenCode; no correría en sandbox iOS"
        case (.bunRuntime, _):
            return "Sin Bun iOS; JS puro en JavaScriptCore/WKWebView no cubre bun:/node:/PTY"
        case (.ptyTTY, .unsupported):
            return "No PTY/TTY: el renderer @opentui no inicializa pantalla"
        case (.spawnExec, .unsupported):
            return "No Process/NSTask en iOS; bash tool no operable"
        case (.nodeFsAndWatch, .partial):
            return "Sources/Workspace + Sources/Tools reimplementan fs/glob en sandbox iOS"
        case (.sqliteBun, .partial):
            return "Sources/Persistence usa SQLite/JSON; no la variante Bun"
        case (.treeSitterNative, .unsupported):
            return "tree-sitter no prebuilt para iOS; sin syntax/AST"
        case (.networkTLSWS, .compatible):
            return "URLSessionWebSocketTask + NWListener disponibles"
        case (.posixEnv, .unsupported):
            return "No SHELL/HOME/EDITOR; el TUI no se inicializa"
        default:
            return nil
        }
    }

    /// Render textual de la matriz (para la TUI).
    public func renderText() -> String {
        var lines: [String] = []
        let title = "OpenCode TUI Compatibility  (host=\(isIOSHost ? "iOS" : "non-iOS"))"
        lines.append(title)
        let line = String(repeating: "=", count: title.count)
        lines.append(line)
        for e in entries {
            let v = "[\(e.verdict.rawValue.uppercased())]"
            let pad = String(repeating: " ", count: max(1, 14 - v.count))
            lines.append("\(v)\(pad)\(e.requirementLabel)")
            lines.append("       ev: \(e.evidence)")
            if let h = e.href { lines.append("       hint: \(h)") }
        }
        lines.append(String(repeating: "=", count: line.count))
        lines.append("canOpenCodeBoot = \(canOpenCodeBoot)")
        if let b = firstBlocker {
            lines.append("FIRST BLOCKER = \(b.requirementLabel): \(b.evidence)")
        }
        return lines.joined(separator: "\n")
    }
}
