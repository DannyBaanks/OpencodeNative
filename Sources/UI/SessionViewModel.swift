import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Línea de la consola (TUI transcript).
public struct TranscriptLine: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable {
        case system, boot, user, assistant, tool, toolResult, error, success
    }
    public let id: String
    public let kind: Kind
    public let text: String
    public let timestamp: Date
    public init(_ kind: Kind, _ text: String, id: String = UUID().uuidString, timestamp: Date = Date()) {
        self.id = id; self.kind = kind; self.text = text; self.timestamp = timestamp
    }
}

/// ViewModel de la sesión consola-first.
/// Conecta el TUI al runtime nativo (harness) y al agente alternativo.
///
/// El agente aquí es el **runtime nativo alternativo** de este proyecto,
/// NO el OpenCode TUI. OpenCode TUI se procesa vía `OpenCodeBootAttempt`
/// y se muestra como transcript de compatibilidad.
@MainActor
public final class SessionViewModel: ObservableObject {
    @Published public var transcript: [TranscriptLine] = []
    @Published public var inputText: String = ""
    @Published public var isProcessing: Bool = false
    @Published public var statusLine: String = "idle"
    @Published public var lastBootAttempt: OpenCodeBootAttempt?
    @Published public var showMatrix: Bool = false

    public enum Provider { case scripted, remote }

    // Runtime alternativo nativo.
    private var workspace: IOSWorkspace?
    private var persistence: IOSPersistence?
    private var modelProvider_any: (any ModelProvider)?
    private var toolExecutor: FileSystemToolExecutor?
    private var agentLoop: AgentLoop?
    private var providerKind: Provider = .scripted
    private var conversationId: String = UUID().uuidString

    public init() {}

    /// Inicializa runtime + emite boot transcript.
    public func initialize() async {
        emit(.system, "opencode-native — compatibility harness v\(Self.appVersion)")
        await runBootAttempt()
        await initRuntime()
    }

    public static var appVersion: String { "0.2.0" }

    // MARK: - Commands

    private let commands: [String] = ["/help", "/matrix", "/boot", "/demo", "/clear", "/provider scripted", "/provider remote"]

    public func handleEnter() {
        guard !isProcessing else { return }
        
        let raw = inputText
        guard !raw.isEmpty else { return }
        inputText = ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        emit(.user, "$ \(trimmed)")
        if trimmed.hasPrefix("/") {
            runSlashCommand(trimmed)
            return
        }
        runAgent(userInput: trimmed)
    }

    private func runSlashCommand(_ cmd: String) {
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let head = parts.first ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        switch head {
        case "/help":
            for c in commands { emit(.system, "  \(c)") }
            emit(.system, "(cualquier otra entrada se envía al agente nativo)")
        case "/matrix":
            showMatrix = true
            emitMatrix()
        case "/boot":
            Task { await runBootAttempt() }
        case "/demo":
            providerKind = .scripted
            Task { await initRuntime(); runAgent(userInput: "demo list-read-write-verify") }
        case "/clear":
            transcript.removeAll()
        case "/provider":
            switch rest {
            case "scripted": providerKind = .scripted; emit(.system, "provider → scripted (offline)")
            case "remote":   providerKind = .remote;   emit(.system, "provider → remote (requiere API key en config). Use /boot para reintentar.")
            default: emit(.error, "uso: /provider scripted | /provider remote")
            }
            Task { await initRuntime() }
        default:
            emit(.error, "comando desconocido: \(head). usa /help")
        }
    }

    private func emitMatrix() {
        guard let ba = lastBootAttempt else { return }
        let r = ba.compatibilityReport
        for e in r.entries {
            let tag = "[\(e.verdict.rawValue.uppercased())]"
            emit(.system, "\(tag.padding(toLength: 12, withPad: " ", startingAt: 0)) \(e.requirementLabel)")
            emit(.system, "       \(e.evidence)")
        }
        emit(r.canOpenCodeBoot ? .success : .error, "canOpenCodeBoot = \(r.canOpenCodeBoot)")
        if let b = r.firstBlocker { emit(.error, "first blocker: \(b.requirementLabel)") }
    }

    // MARK: - Boot attempt

    public func runBootAttempt() async {
        let matrix = IOSCapabilityMatrix.probeCurrent()
        let attempt = OpenCodeBootAttempt.run(matrix: matrix)
        lastBootAttempt = attempt
        for line in attempt.transcript { emit(.boot, line) }
    }

    // MARK: - Runtime init

    private func initRuntime() async {
        do {
            let ws = try IOSWorkspace()
            let ps = try IOSPersistence()
            self.workspace = ws
            self.persistence = ps
            let provider: any ModelProvider
            switch providerKind {
            case .scripted:
                provider = ScriptedModelProvider(script: ScriptedModelProvider.demoScript())
            case .remote:
                let remote = RemoteModelProvider()
                let savedConfig = try? await ps.loadConfiguration()
                // Cargar API key desde Keychain
                let apiKey = (try? await ps.loadAPIKey(provider: "remote")) ?? ""
                let baseURL = savedConfig?.defaultModelProvider == "anthropic" 
                    ? "https://api.anthropic.com/v1" 
                    : (savedConfig?.workspacePath ?? "https://api.openai.com/v1")
                try await remote.configure(ModelConfiguration(apiKey: apiKey, baseURL: baseURL))
                provider = remote
            }
            self.modelProvider_any = provider
            let exec = FileSystemToolExecutor(workspace: ws)
            self.toolExecutor = exec
            let ctx = AgentContext(
                conversationId: conversationId,
                workspace: ws,
                persistence: ps,
                modelProvider: provider,
                toolExecutor: exec,
                systemPrompt: systemPromptText(),
                maxTurns: 12,
                permissionHandler: { [weak self] request in
                    // En una implementación real, esto mostraría UI y esperaría respuesta
                    // Por ahora, auto-permitimos para demo
                    return PermissionResponse(requestId: request.id, decision: .allowOnce)
                }
            )
            let loop = AgentLoop(context: ctx)
            await loop.setEventHandler { [weak self] event in
                await MainActor.run { self?.handleAgentEvent(event) }
            }
            self.agentLoop = loop
            statusLine = "runtime ready (\(providerKind == .scripted ? "scripted" : "remote"))"
            emit(.success, "runtime nativo alternativo listo. /help para comandos.")
        } catch {
            statusLine = "runtime error"
            emit(.error, "init runtime: \(error.localizedDescription)")
        }
    }

    private func systemPromptText() -> String {
        """
        Eres un asistente que opera dentro del runtime nativo alternativo de OpencodeNative en iOS.
        No eres OpenCode: el TUI real de OpenCode NO puede arrancar en iOS (ver boot attempt).
        Tienes 8 tools de filesystem restringidas al sandbox. Sin shell, sin git, sin compilar.
        Responde de forma concisa. Cuando el usuario pida algo imposible en iOS, explícalo.
        """
    }

    // MARK: - Agent run

    private func runAgent(userInput: String) {
        guard let loop = agentLoop else {
            emit(.error, "runtime no inicializado. ejecuta /boot")
            return
        }
        isProcessing = true
        statusLine = "agent running…"
        Task {
            do {
                _ = try await loop.run(userInput: userInput)
                await MainActor.run { self.isProcessing = false; self.statusLine = "idle" }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.statusLine = "agent error"
                    self.emit(.error, error.localizedDescription)
                }
            }
        }
    }

    private func handleAgentEvent(_ event: AgentLoopEvent) {
        switch event {
        case .turnStarted(let t):
            emit(.system, "— turn \(t) —")
        case .modelResponse(let r):
            if !r.content.isEmpty { emit(.assistant, r.content) }
            if let calls = r.toolCalls, !calls.isEmpty {
                for c in calls {
                    let args = c.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                    emit(.tool, "→ \(c.name)(\(args))")
                }
            }
        case .toolResult(let res):
            if let err = res.error { emit(.error, "✗ tool error: \(err)") }
            else { emit(.toolResult, "← \(res.output)") }
        case .error(let e):
            emit(.error, e.localizedDescription)
        case .finished(let final):
            emit(.success, "✓ done")
            _ = final
        default:
            break
        }
    }

    // MARK: - emit

    private func emit(_ kind: TranscriptLine.Kind, _ text: String) {
        transcript.append(TranscriptLine(kind, text))
    }
}
