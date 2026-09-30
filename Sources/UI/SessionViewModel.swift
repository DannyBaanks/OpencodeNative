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
/// NO el IysCode TUI. IysCode TUI se procesa vía `OpenCodeBootAttempt`
/// y se muestra como transcript de compatibilidad.
@MainActor
public final class SessionViewModel: ObservableObject {
    @Published public var transcript: [TranscriptLine] = []
    @Published public var inputText: String = ""
    @Published public var isProcessing: Bool = false
    @Published public var statusLine: String = "idle"
    @Published public var lastBootAttempt: OpenCodeBootAttempt?
    @Published public var showMatrix: Bool = false
    @Published public private(set) var pendingPermission: PermissionRequest?

    public enum Provider { case scripted, remote }

    // Runtime alternativo nativo.
    private var workspace: IOSWorkspace?
    private var persistence: IOSPersistence?
    private var modelProvider_any: (any ModelProvider)?
    private var toolExecutor: FileSystemToolExecutor?
    private var agentLoop: AgentLoop?
    private var permissionContinuation: CheckedContinuation<PermissionResponse, Never>?
    private var agentTask: Task<Void, Never>?
    private var providerKind: Provider = .scripted
    private var conversationId: String = UUID().uuidString

    public init() {}

    /// Inicializa runtime + emite boot transcript.
    public func initialize() async {
        emit(.system, "iyscodemovil — compatibility harness v\(Self.appVersion)")
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
        denyPendingPermission()
        agentTask?.cancel()
        agentTask = nil
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
                // workspacePath is a folder, not an API endpoint; it used to be sent as the base URL.
                let baseURL = savedConfig?.defaultModelProvider == "anthropic"
                    ? "https://api.anthropic.com/v1"
                    : "https://api.openai.com/v1"
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
                    guard let self else { return PermissionResponse(requestId: request.id, decision: .deny) }
                    return await self.waitForPermission(request)
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
        GUSMobileRole.mobile.systemPrompt
    }

    private func waitForPermission(_ request: PermissionRequest) async -> PermissionResponse {
        guard pendingPermission.map(\.id) == nil else {
            return PermissionResponse(requestId: request.id, decision: .deny)
        }
        pendingPermission = request
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard pendingPermission?.id == request.id else {
                    continuation.resume(returning: PermissionResponse(requestId: request.id, decision: .deny))
                    return
                }
                permissionContinuation = continuation
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.denyPendingPermission(requestID: request.id) }
        }
    }

    /// Resolves only the currently displayed request; stale UI actions cannot approve a later tool call.
    public func respondToPermission(requestID: String, decision: PermissionResponse.Decision) {
        guard pendingPermission?.id == requestID else { return }
        let resolved = PermissionDecisionGate.decision(
            requestID: requestID,
            pendingRequestID: pendingPermission?.id,
            proposed: decision
        )
        pendingPermission = nil
        let continuation = permissionContinuation
        permissionContinuation = nil
        continuation?.resume(returning: PermissionResponse(requestId: requestID, decision: resolved))
    }

    public func cancelAgent() {
        denyPendingPermission()
        agentTask?.cancel()
        agentTask = nil
        isProcessing = false
        statusLine = "idle"
    }

    private func denyPendingPermission(requestID: String? = nil) {
        guard let request = pendingPermission,
              requestID == nil || request.id == requestID else { return }
        respondToPermission(requestID: request.id, decision: .deny)
    }

    // MARK: - Agent run

    private func runAgent(userInput: String) {
        guard let loop = agentLoop else {
            emit(.error, "runtime no inicializado. ejecuta /boot")
            return
        }
        isProcessing = true
        statusLine = "agent running…"
        agentTask = Task {
            do {
                _ = try await loop.run(userInput: userInput)
                await MainActor.run { self.isProcessing = false; self.statusLine = "idle"; self.agentTask = nil }
            } catch is CancellationError {
                await MainActor.run {
                    self.denyPendingPermission()
                    self.isProcessing = false
                    self.statusLine = "idle"
                    self.agentTask = nil
                }
            } catch {
                await MainActor.run {
                    self.denyPendingPermission()
                    self.isProcessing = false
                    self.agentTask = nil
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
