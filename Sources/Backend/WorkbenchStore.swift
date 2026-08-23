import Foundation
import SwiftUI

@MainActor
public final class WorkbenchStore: ObservableObject {
    @Published public var sessionState = ActiveSessionState()
    @Published public private(set) var projects: [Project] = []
    @Published public private(set) var sessions: [Session] = []
    @Published public private(set) var backendMode: BackendMode = .unconfigured
    @Published public private(set) var connectionStatus: String = ""
    @Published public private(set) var isConnecting: Bool = false
    @Published public var availableModels: [ModelInfo] = []
    @Published public var availableAgents: [String] = []
    @Published public var availableCommands: [CommandInfo] = []
    @Published public var fileTree: [WorkbenchFileNode] = []
    @Published public var diffFiles: [SessionDiffFile] = []
    @Published public var shellHistory: [(command: String, result: ShellResult?)] = []
    
    private var currentProjectID: String?
    private var currentSessionID: String?
    var currentBackend: (any WorkbenchBackend)?
    private var pairingStore = PairingStore()
    private var backendEventTask: Task<Void, Never>?
    private var isProcessingRemote = false
    
    public init() {}
    
    public func connectRemote(_ rawPairingLink: String) async {
        guard !isConnecting else { return }
        isConnecting = true
        connectionStatus = "connecting..."
        
        do {
            let pairing = try OpenCodePairing.parse(rawPairingLink)
            let backend = OpenCodeServerBackend(pairing: pairing)
            currentBackend = backend
            backendMode = .remote
            
            try await backend.connectRemote(pairing: pairing)
            
            let project = Project(
                id: "remote:\(pairing.host):\(pairing.port)",
                name: "OpenCode @ \(pairing.host)",
                path: pairing.directory.isEmpty ? "remote" : pairing.directory,
                avatarColor: .white,
                sessionCount: 0
            )
            projects = [project]
            currentProjectID = project.id
            sessionState.currentProject = project
            
            let remoteSessions = try await backend.listSessions(projectID: project.id)
            sessions = remoteSessions
            if let first = remoteSessions.first {
                sessionState.currentSession = first
                currentSessionID = first.id
            }
            
            sessionState.selectedModel = ModelInfo(
                name: "OpenCode server default",
                provider: "OpenCode",
                providerIcon: "terminal",
                isLocal: false,
                route: "opencode-server"
            )
            
            connectionStatus = await backend.connectionStatus
            isConnecting = false
            sessionState.clearTimeline()
            addSystemEvent("OpenCode connected")
            
            try await pairingStore.save(pairing)
            
            await loadModelsAndAgents()
            await subscribeToBackendEvents(backend)
            
        } catch {
            isConnecting = false
            backendMode = .unconfigured
            connectionStatus = "error: \(error.localizedDescription)"
        }
    }
    
    public func disconnect() async {
        await currentBackend?.disconnect()
        currentBackend = nil
        backendMode = .unconfigured
        connectionStatus = ""
        isConnecting = false
        projects = []
        sessions = []
        availableModels = []
        availableAgents = []
        availableCommands = []
        fileTree = []
        diffFiles = []
        shellHistory = []
        sessionState.currentProject = nil
        sessionState.currentSession = nil
        sessionState.clearTimeline()
        currentProjectID = nil
        currentSessionID = nil
    }
    
    public func useNativeRuntime() async {
        do {
            let backend = NativeSwiftBackend()
            currentBackend = backend
            backendMode = .native
            
            try await backend.useNativeRuntime()
            
            projects = try await backend.listProjects()
            if let project = projects.first {
                currentProjectID = project.id
                sessionState.currentProject = project
                sessions = try await backend.listSessions(projectID: project.id)
                if let first = sessions.first {
                    sessionState.currentSession = first
                    currentSessionID = first.id
                }
            }
            
            connectionStatus = await backend.connectionStatus
            sessionState.clearTimeline()
            addSystemEvent("Native Swift runtime ready")
            
            await loadModelsAndAgents()
            await subscribeToBackendEvents(backend)
            
        } catch {
            backendMode = .unconfigured
            connectionStatus = "error: \(error.localizedDescription)"
        }
    }
    
    public func reconnectStoredPairing() async {
        if let stored = try? await pairingStore.load() {
            let pairing = OpenCodePairing(
                host: stored.host,
                port: stored.port,
                username: stored.username,
                password: stored.password,
                directory: stored.directory
            )
            await connectRemote(pairing.rawValue)
        }
    }
    
    public func forgetPairing() async {
        try? await pairingStore.clear()
    }
    
    public func hasStoredPairing() async -> Bool {
        await pairingStore.hasStoredPairing()
    }
    
    public func selectProject(_ project: Project) async {
        guard backendMode != .unconfigured else { return }
        currentProjectID = project.id
        sessionState.currentProject = project
        
        if let backend = currentBackend {
            do {
                sessions = try await backend.listSessions(projectID: project.id)
                if let first = sessions.first {
                    sessionState.currentSession = first
                    currentSessionID = first.id
                } else {
                    sessionState.currentSession = nil
                    currentSessionID = nil
                }
            } catch {
                addErrorEvent("Failed to load sessions: \(error.localizedDescription)")
            }
        }
    }
    
    public func selectSession(_ session: Session) async {
        guard backendMode != .unconfigured else { return }
        sessionState.currentSession = session
        currentSessionID = session.id
        sessionState.clearTimeline()
        
        if let backend = currentBackend {
            do {
                try await backend.selectSession(session.id)
                await backend.loadHistory(sessionID: session.id)
            } catch {
                addErrorEvent("Failed to load session: \(error.localizedDescription)")
            }
        }
    }
    
    public func createNewSession(in project: Project, title: String) async -> Session? {
        guard let backend = currentBackend else { return nil }
        do {
            let session = try await backend.createSession(projectID: project.id, title: title.isEmpty ? "New Session" : title)
            sessions.append(session)
            sessionState.currentSession = session
            currentSessionID = session.id
            return session
        } catch {
            addErrorEvent("Failed to create session: \(error.localizedDescription)")
            return nil
        }
    }
    
    public func renameSession(_ session: Session, title: String) async {
        guard let backend = currentBackend else { return }
        do {
            try await backend.renameSession(sessionID: session.id, title: title)
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx] = Session(id: session.id, projectId: session.projectId, title: title, lastEventSummary: session.lastEventSummary, timestamp: session.timestamp, agentMode: session.agentMode, isRunning: session.isRunning)
            }
            if sessionState.currentSession?.id == session.id {
                sessionState.currentSession = sessions.first { $0.id == session.id }
            }
        } catch {
            addErrorEvent("Failed to rename session: \(error.localizedDescription)")
        }
    }
    
    public func deleteSession(_ session: Session) async {
        guard let backend = currentBackend else { return }
        do {
            try await backend.deleteSession(sessionID: session.id)
            sessions.removeAll { $0.id == session.id }
            if sessionState.currentSession?.id == session.id {
                sessionState.currentSession = sessions.first
                currentSessionID = sessions.first?.id
            }
        } catch {
            addErrorEvent("Failed to delete session: \(error.localizedDescription)")
        }
    }
    
    public func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sessionState.isProcessing else { return }
        
        let userEvent = TimelineEvent.userPrompt(
            trimmed,
            attachments: sessionState.composerAttachments,
            agentMode: sessionState.agentMode
        )
        sessionState.addEvent(userEvent)
        sessionState.composerAttachments.removeAll()
        
        guard let backend = currentBackend else {
            addErrorEvent("No backend available")
            return
        }
        
        if backendMode == .remote {
            isProcessingRemote = true
        }
        sessionState.isProcessing = true
        
        let agent = sessionState.agentMode.rawValue.lowercased()
        let model = sessionState.selectedModel
        
        Task { [weak self] in
            guard let self else { return }
            do {
                try await backend.sendPrompt(trimmed, agent: agent, model: model)
            } catch is CancellationError {
                await MainActor.run {
                    self.sessionState.isProcessing = false
                    self.isProcessingRemote = false
                    self.addSystemEvent("Stopped")
                }
            } catch {
                await MainActor.run {
                    self.sessionState.isProcessing = false
                    self.isProcessingRemote = false
                    self.addErrorEvent("Prompt failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    public func cancelCurrentRun() {
        guard sessionState.isProcessing else { return }
        
        if backendMode == .remote {
            isProcessingRemote = false
            let sessionID = currentSessionID
            let backend = currentBackend
            Task { [weak self] in
                if let sessionID, let backend {
                    try? await backend.abort()
                }
                await MainActor.run { [weak self] in
                    self?.sessionState.isProcessing = false
                    self?.addSystemEvent("Stopped")
                }
            }
            return
        }
        
        Task { [weak self] in
            try? await self?.currentBackend?.abort()
            await MainActor.run { [weak self] in
                self?.sessionState.isProcessing = false
                self?.addSystemEvent("Stopped")
            }
        }
    }
    
    public func respondToPermission(requestId: String, decision: PermissionResponse.Decision) {
        guard let backend = currentBackend else {
            addErrorEvent("No backend available for permission")
            return
        }
        
        sessionState.pendingPermission = nil
        
        Task { [weak self] in
            do {
                try await backend.replyPermission(requestID: requestId, decision: decision)
                await MainActor.run { [weak self] in
                    let responseText = decision.rawValue
                    self?.addSystemEvent("Permission \(responseText)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.addErrorEvent("Permission reply failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    public func setModel(_ model: ModelInfo) {
        if backendMode == .remote {
            addSystemEvent("Remote model/provider selection is controlled by the linked OpenCode server")
            return
        }
        
        sessionState.selectedModel = model
        Task { [weak self] in
            await MainActor.run { [weak self] in
                self?.addSystemEvent("Model: \(model.name) (\(model.provider))")
            }
        }
    }
    
    public func setAgentMode(_ mode: AgentMode) {
        sessionState.agentMode = mode
        addSystemEvent("Agent mode: \(mode.rawValue)")
    }
    
    public func loadFiles(path: String = "") async {
        guard let backend = currentBackend else { return }
        do {
            fileTree = try await backend.listFiles(path: path)
        } catch {
            addErrorEvent("Failed to load files: \(error.localizedDescription)")
        }
    }
    
    public func loadFileContent(path: String) async -> WorkbenchFileContent? {
        guard let backend = currentBackend else { return nil }
        do {
            return try await backend.fileContent(path: path)
        } catch {
            addErrorEvent("Failed to load file: \(error.localizedDescription)")
            return nil
        }
    }
    
    public func loadDiff(sessionID: String) async {
        guard let backend = currentBackend else { return }
        do {
            diffFiles = try await backend.sessionDiff(sessionID: sessionID)
        } catch {
            addErrorEvent("Failed to load diff: \(error.localizedDescription)")
        }
    }
    
    public func runShellCommand(_ command: String, agent: String?) async {
        guard let backend = currentBackend else { return }
        do {
            let result = try await backend.runShell(command: command, agent: agent)
            shellHistory.append((command, result))
            for text in result.textParts {
                addSystemEvent(text)
            }
            if let error = result.error {
                addErrorEvent("Shell error: \(error)")
            }
        } catch {
            addErrorEvent("Shell failed: \(error.localizedDescription)")
        }
    }
    
    public func loadModelsAndAgents() async {
        guard let backend = currentBackend else { return }
        do {
            let providers = try await backend.availableProviders()
            var models: [ModelInfo] = []
            for provider in providers.all {
                if let providerModels = provider.models {
                    for (modelID, _) in providerModels {
                        models.append(ModelInfo(
                            name: "\(provider.name) / \(modelID)",
                            provider: provider.name,
                            providerIcon: "cpu",
                            isLocal: false,
                            apiModelId: modelID,
                            route: provider.id
                        ))
                    }
                }
            }
            if models.isEmpty {
                models.append(ModelInfo(name: "OpenCode server default", provider: "OpenCode", providerIcon: "terminal", isLocal: false, route: "opencode-server"))
            }
            availableModels = models
            
            let cfg = try await backend.config()
            if let agents = cfg.agents {
                availableAgents = Array(agents.keys).sorted()
            } else {
                availableAgents = ["build", "plan", "explore", "review", "custom"]
            }
            
            let cmds = try await backend.availableCommands()
            availableCommands = cmds
            
        } catch {
            addErrorEvent("Failed to load models/agents: \(error.localizedDescription)")
        }
    }
    
    private func subscribeToBackendEvents(_ backend: any WorkbenchBackend) async {
        backendEventTask?.cancel()
        backendEventTask = Task { [weak self] in
            for await event in backend.eventStream {
                guard !Task.isCancelled else { break }
                await self?.handleBackendEvent(event)
            }
        }
    }
    
    private func handleBackendEvent(_ event: WorkbenchEvent) async {
        switch event {
        case .connected:
            sessionState.isProcessing = false
            isProcessingRemote = false
            addSystemEvent("Connected")
            
        case .disconnected(let reason):
            sessionState.isProcessing = false
            isProcessingRemote = false
            if let reason { addSystemEvent("Disconnected: \(reason)") }
            
        case .partUpdated(let partID, let kind, let text, let tool, let callID, let status, let input, let output, let error):
            handlePartUpdate(partID: partID, kind: kind, text: text, tool: tool, callID: callID, status: status, input: input, output: output, error: error)
            
        case .permissionAsked(let requestID, let sessionID, let tool, let command, let explanation):
            if sessionID == currentSessionID {
                sessionState.pendingPermission = TimelineEvent.permission(
                    requestId: requestID,
                    tool: tool,
                    command: command,
                    explanation: explanation,
                    scope: backendMode == .remote ? "remote workspace" : "sandbox",
                    agentMode: sessionState.agentMode
                )
            }
            
        case .sessionIdle(let sessionID):
            if sessionID == currentSessionID {
                sessionState.isProcessing = false
                isProcessingRemote = false
                addSuccessEvent("Done")
            }
            
        case .sessionError(let message):
            sessionState.isProcessing = false
            isProcessingRemote = false
            addErrorEvent(message)
            
        case .sessionsChanged:
            if let projectID = currentProjectID, let backend = currentBackend {
                sessions = (try? await backend.listSessions(projectID: projectID)) ?? []
            }
            
        case .agentModeChanged(let mode):
            sessionState.agentMode = mode
            
        case .modelChanged(let model):
            if let model { sessionState.selectedModel = model }
            
        case .filesChanged:
            await loadFiles()
            
        default:
            break
        }
    }
    
    private func handlePartUpdate(partID: String, kind: String, text: String?, tool: String?, callID: String?, status: String?, input: [String: String], output: String?, error: String?) {
        let eventID = callID ?? partID
        
        if kind == "text", let text = text, !text.isEmpty {
            if let index = sessionState.timelineEvents.firstIndex(where: { $0.id == eventID }) {
                sessionState.timelineEvents[index].assistantText = text
            } else {
                let event = TimelineEvent.assistantText(text, agentMode: sessionState.agentMode)
                sessionState.addEvent(event)
            }
        } else if kind == "tool" {
            let state: ToolCallState
            switch status {
            case "completed": state = .success
            case "error": state = .failed
            default: state = .running
            }
            if let index = sessionState.timelineEvents.firstIndex(where: { $0.id == eventID }) {
                sessionState.updateToolCall(id: eventID, state: state, output: output ?? error, duration: nil)
            } else {
                let toolName = tool ?? "tool"
                let event = TimelineEvent.toolCall(id: eventID, name: toolName, arguments: input, state: state, agentMode: sessionState.agentMode)
                sessionState.addEvent(event)
                if let output = output ?? error {
                    sessionState.updateToolCall(id: eventID, state: state, output: output, duration: nil)
                }
            }
        } else if kind == "reasoning", let text = text, !text.isEmpty {
            let event = TimelineEvent.system("thinking · \(text)")
            sessionState.addEvent(event)
        } else if kind == "userPrompt", let text = text {
            let event = TimelineEvent.userPrompt(text, agentMode: sessionState.agentMode)
            sessionState.addEvent(event)
        } else if kind == "system", let text = text {
            addSystemEvent(text)
        }
    }
    
    private func addSystemEvent(_ text: String) {
        let event = TimelineEvent.system(text)
        sessionState.addEvent(event)
    }
    
    private func addErrorEvent(_ text: String) {
        sessionState.addEvent(TimelineEvent.system("Error: \(text)"))
    }
    
    private func addSuccessEvent(_ text: String) {
        sessionState.addEvent(TimelineEvent.system(text))
    }
    
    public func addAttachment(_ attachment: Attachment) {
        sessionState.composerAttachments.append(attachment)
    }
    
    public func removeAttachment(_ attachment: Attachment) {
        sessionState.composerAttachments.removeAll { $0.id == attachment.id }
    }
    
    public func saveAPIKeys(openAI: String, anthropic: String, google: String) async {
        if !openAI.isEmpty {
            do { try await (currentBackend as? NativeSwiftBackend)?.persistence?.saveAPIKey(provider: "openai", key: openAI) } catch {}
        }
        if !anthropic.isEmpty {
            do { try await (currentBackend as? NativeSwiftBackend)?.persistence?.saveAPIKey(provider: "anthropic", key: anthropic) } catch {}
        }
        if !google.isEmpty {
            do { try await (currentBackend as? NativeSwiftBackend)?.persistence?.saveAPIKey(provider: "google", key: google) } catch {}
        }
        addSystemEvent("API keys saved")
    }
}