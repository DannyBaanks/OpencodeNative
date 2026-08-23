import Foundation
import SwiftUI

// MARK: - Session View Model Adapter

/// Bridges the existing SessionViewModel (TUI/console) with the new ActiveSessionState (iOS 27 workbench)
@MainActor
public final class SessionAdapter: ObservableObject {
    public enum BackendMode: String, Sendable {
        case unconfigured
        case native
        case remote
    }

    @Published public var sessionState = ActiveSessionState()
    @Published public var projects: [Project] = []
    @Published public private(set) var backendMode: BackendMode = .unconfigured
    @Published public private(set) var connectionStatus: String = ""
    @Published public private(set) var isConnecting: Bool = false

    private var originalVM: SessionViewModel?
    private var agentLoop: AgentLoop?
    private var workspace: IOSWorkspace?
    private var persistence: IOSPersistence?
    private var modelProvider: (any ModelProvider)?
    private var toolExecutor: FileSystemToolExecutor?
    private let conversationId = UUID().uuidString
    private var runningTask: Task<Void, Never>?
    private var configuredModel: ModelInfo?

    // Official OpenCode headless server backend
    private var remoteClient: OpenCodeRemoteClient?
    private var remoteEventTask: Task<Void, Never>?
    private var remotePartTimelineIDs: [String: String] = [:]
    private var remotePermissionSessionID: String?

    // Permission handling
    private var pendingPermissionContinuation: CheckedContinuation<PermissionResponse, Never>?
    private var pendingPermissionRequestId: String?

    public init() {}

    public func useNativeRuntime() {
        guard backendMode != .native else { return }
        remoteEventTask?.cancel()
        remoteEventTask = nil
        remoteClient = nil
        backendMode = .native
        connectionStatus = "native runtime"
        setupDemoProject()
        Task { await initializeRuntime() }
    }

    public func connectRemote(_ rawPairingLink: String) {
        guard !isConnecting else { return }
        isConnecting = true
        connectionStatus = "connecting..."

        Task { [weak self] in
            guard let self else { return }
            do {
                let pairing = try OpenCodePairing.parse(rawPairingLink)
                let client = OpenCodeRemoteClient(pairing: pairing)
                let health = try await client.health()
                guard health.healthy else { throw OpenCodeRemoteError.invalidResponse }

                var remoteSessions = try await client.listSessions()
                if remoteSessions.isEmpty {
                    remoteSessions = [try await client.createSession(title: "OpencodeNative")]
                }

                let project = Project(
                    id: "remote:\(pairing.host):\(pairing.port)",
                    name: "OpenCode @ \(pairing.host)",
                    path: pairing.directory.isEmpty ? "remote" : pairing.directory,
                    avatarColor: .white,
                    sessionCount: remoteSessions.count
                )
                let sessions = remoteSessions.map { remote in
                    Session(
                        id: remote.id,
                        projectId: project.id,
                        title: remote.title,
                        lastEventSummary: "OpenCode remote session",
                        timestamp: remote.updatedAt,
                        agentMode: .build,
                        isRunning: false
                    )
                }

                self.remoteClient = client
                self.backendMode = .remote
                self.projects = [project]
                self.sessionState.currentProject = project
                self.sessionState.currentSession = sessions.first
                self.sessionState.selectedModel = ModelInfo(
                    name: "OpenCode server default",
                    provider: "OpenCode",
                    providerIcon: "terminal",
                    isLocal: false,
                    route: "opencode-server"
                )
                self.connectionStatus = "connected Â· OpenCode \(health.version) Â· \(pairing.host):\(pairing.port)"
                self.isConnecting = false
                self.sessionState.clearTimeline()
                self.addSystemEvent("OpenCode \(health.version) connected")
                self.addSystemEvent(pairing.directory.isEmpty ? "remote workspace" : pairing.directory)

                if let session = sessions.first {
                    await self.loadRemoteHistory(sessionID: session.id)
                }
                self.startRemoteEvents(client)
            } catch {
                self.isConnecting = false
                self.backendMode = .unconfigured
                self.connectionStatus = "error: \(error.localizedDescription)"
            }
        }
    }

    public func disconnect() {
        cancelCurrentRun()
        remoteEventTask?.cancel()
        remoteEventTask = nil
        remoteClient = nil
        remotePartTimelineIDs.removeAll()
        remotePermissionSessionID = nil
        backendMode = .unconfigured
        connectionStatus = ""
        projects = []
        sessionState.currentProject = nil
        sessionState.currentSession = nil
        sessionState.clearTimeline()
    }

    // MARK: - Project/Session Management

    private func setupDemoProject() {
        let project = Project.demoProjects[0]
        sessionState.currentProject = project

        let sessions = Session.demoSessions(for: project)
        if let firstSession = sessions.first {
            sessionState.currentSession = firstSession
        }
    }

    public func selectProject(_ project: Project) {
        sessionState.currentProject = project
        // Load sessions for project
    }

    public func selectSession(_ session: Session) {
        sessionState.currentSession = session
        sessionState.clearTimeline()
        if backendMode == .remote {
            Task { await loadRemoteHistory(sessionID: session.id) }
        } else {
            loadSessionHistory(session)
        }
    }

    public func createNewSession(in project: Project, title: String) -> Session {
        let session = Session(projectId: project.id, title: title.isEmpty ? "New Session" : title)
        // Persist and select
        selectSession(session)
        return session
    }

    // MARK: - Runtime Initialization

    private func initializeRuntime() async {
        do {
            let ws = try IOSWorkspace()
            let ps = try IOSPersistence()
            self.workspace = ws
            self.persistence = ps

            // Use scripted provider for demo
            let provider = ScriptedModelProvider(script: ScriptedModelProvider.demoScript())
            self.modelProvider = provider

            let exec = FileSystemToolExecutor(workspace: ws)
            self.toolExecutor = exec

            let ctx = AgentContext(
                conversationId: conversationId,
                workspace: ws,
                persistence: ps,
                modelProvider: provider,
                modelName: provider.availableModels.first,
                toolExecutor: exec,
                systemPrompt: systemPromptText(),
                maxTurns: 12,
                permissionHandler: { [weak self] request in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(returning: PermissionResponse(requestId: request.id, decision: .deny))
                                return
                            }
                            self.pendingPermissionContinuation = continuation
                            self.pendingPermissionRequestId = request.id
                            self.sessionState.pendingPermission = TimelineEvent.permission(
                                requestId: request.id,
                                tool: request.toolName,
                                command: request.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
                                explanation: request.reason,
                                scope: "workspace",
                                agentMode: self.sessionState.agentMode
                            )
                        }
                    }
                }
            )

            let loop = AgentLoop(context: ctx)
            await loop.setEventHandler { [weak self] event in
                await MainActor.run { self?.handleAgentEvent(event) }
            }
            self.agentLoop = loop

            let initialModel = ModelInfo(
                name: "Demo Scripted",
                provider: "Local",
                providerIcon: "cpu",
                isLocal: true,
                apiModelId: "scripted-1",
                route: "scripted"
            )
            configuredModel = initialModel
            sessionState.selectedModel = initialModel

            // Add welcome message
            addSystemEvent("OpenCodeNative — iOS 27 Workbench ready")
            addSystemEvent("Agent mode: \(sessionState.agentMode.rawValue) | Model: \(sessionState.selectedModel?.name ?? "none")")
        } catch {
            addErrorEvent("Runtime init failed: \(error.localizedDescription)")
        }
    }

    private func systemPromptText() -> String {
        """
        You are an assistant in OpenCodeNative, a native iOS workbench for OpenCode.
        You operate within the iOS sandbox with filesystem tools.
        Be concise and technical. Use tools to accomplish tasks.
        """
    }

    // MARK: - Agent Event Handling

    private func handleAgentEvent(_ event: AgentLoopEvent) {
        switch event {
        case .turnStarted(let turn):
            addSystemEvent("— turn \(turn) —")

        case .modelResponse(let response):
            if !response.content.isEmpty {
                let event = TimelineEvent.assistantText(response.content, agentMode: sessionState.agentMode)
                sessionState.addEvent(event)
            }
            if let calls = response.toolCalls, !calls.isEmpty {
                for call in calls {
                    let event = TimelineEvent.toolCall(
                        id: call.id,
                        name: call.name,
                        arguments: call.arguments,
                        state: .running,
                        agentMode: sessionState.agentMode
                    )
                    sessionState.addEvent(event)
                }
            }

        case .toolResult(let result):
            if let error = result.error {
                sessionState.updateToolCall(id: result.toolCallId, state: .failed, output: error, duration: result.duration)
                addErrorEvent("Tool error: \(error)")
            } else {
                sessionState.updateToolCall(id: result.toolCallId, state: .success, output: result.output, duration: result.duration)
            }

        case .error(let error):
            addErrorEvent(error.localizedDescription)

        case .finished(let final):
            addSuccessEvent("Done")
            _ = final

        default:
            break
        }
    }


    // MARK: - User Input Handling

    public func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sessionState.isProcessing else { return }

        if backendMode == .remote {
            sendRemotePrompt(trimmed)
            return
        }

        guard let loop = agentLoop else {
            addErrorEvent("Agent runtime is not ready yet")
            return
        }

        let userEvent = TimelineEvent.userPrompt(
            trimmed,
            attachments: sessionState.composerAttachments,
            agentMode: sessionState.agentMode
        )
        sessionState.addEvent(userEvent)
        sessionState.composerAttachments.removeAll()

        sessionState.isProcessing = true
        runningTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await loop.run(userInput: trimmed)
                guard !Task.isCancelled else { throw CancellationError() }
                self.sessionState.isProcessing = false
                self.runningTask = nil
            } catch is CancellationError {
                self.sessionState.isProcessing = false
                self.runningTask = nil
                self.addSystemEvent("Stopped")
            } catch {
                self.sessionState.isProcessing = false
                self.runningTask = nil
                self.addErrorEvent(error.localizedDescription)
            }
        }
    }

    public func cancelCurrentRun() {
        guard sessionState.isProcessing else { return }

        if backendMode == .remote {
            let sessionID = sessionState.currentSession?.id
            let client = remoteClient
            runningTask?.cancel()
            runningTask = nil
            sessionState.isProcessing = false
            if let sessionID, let client {
                Task { try? await client.abort(sessionID: sessionID) }
            }
            addSystemEvent("Stopped")
            return
        }

        if let continuation = pendingPermissionContinuation {
            let requestId = pendingPermissionRequestId ?? sessionState.pendingPermission?.permissionRequestId ?? UUID().uuidString
            pendingPermissionContinuation = nil
            pendingPermissionRequestId = nil
            sessionState.pendingPermission = nil
            continuation.resume(returning: PermissionResponse(requestId: requestId, decision: .deny))
        }

        runningTask?.cancel()
    }

    // MARK: - Agent Mode Switching

    public func setAgentMode(_ mode: AgentMode) {
        sessionState.agentMode = mode
        // In a real implementation, this might require reinitializing the agent loop
        addSystemEvent("Agent mode: \(mode.rawValue)")
    }

    // MARK: - Model Switching

    public func setModel(_ model: ModelInfo) {
        if backendMode == .remote {
            addSystemEvent("Remote model/provider selection is controlled by the linked OpenCode server")
            return
        }

        let providerId = model.provider.lowercased()
        let isScriptedDemo = providerId == "local" && model.apiModelId == "scripted-1"
        let isSupported = isScriptedDemo || providerId == "openai"

        guard isSupported else {
            addErrorEvent("\(model.provider) requires a native provider adapter or an OpenAI-compatible proxy; direct routing is not implemented yet.")
            if let configuredModel {
                sessionState.selectedModel = configuredModel
            }
            return
        }

        guard configuredModel?.id != model.id else { return }
        sessionState.selectedModel = model
        Task { await reinitializeWithModel(model) }
    }

    private func reinitializeWithModel(_ model: ModelInfo) async {
        do {
            // Keep existing workspace and persistence
            guard let ws = workspace, let ps = persistence else {
                await initializeRuntime()
                return
            }

            let provider: any ModelProvider
            if model.provider.lowercased() == "local", model.apiModelId == "scripted-1" {
                provider = ScriptedModelProvider(script: ScriptedModelProvider.demoScript())
            } else {
                let providerId = model.provider.lowercased()
                guard providerId == "openai" else {
                    throw ModelProviderError.unsupportedFeature(
                        "Direct \(model.provider) protocol is not implemented; use an OpenAI-compatible proxy."
                    )
                }

                let apiKey = (try? await ps.loadAPIKey(provider: providerId)) ?? ""
                guard !apiKey.isEmpty else {
                    throw ModelProviderError.notConfigured("No API key stored for \(model.provider)")
                }

                let remote = RemoteModelProvider(id: providerId, name: model.provider)
                try await remote.configure(
                    ModelConfiguration(
                        apiKey: apiKey,
                        baseURL: "https://api.openai.com/v1"
                    )
                )
                provider = remote
            }

            self.modelProvider = provider
            let exec = FileSystemToolExecutor(workspace: ws)
            self.toolExecutor = exec

            let ctx = AgentContext(
                conversationId: conversationId,
                workspace: ws,
                persistence: ps,
                modelProvider: provider,
                modelName: model.apiModelId ?? model.name,
                toolExecutor: exec,
                systemPrompt: systemPromptText(),
                maxTurns: 12,
                permissionHandler: { [weak self] request in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor [weak self] in
                            guard let self else {
                                continuation.resume(returning: PermissionResponse(requestId: request.id, decision: .deny))
                                return
                            }
                            self.pendingPermissionContinuation = continuation
                            self.pendingPermissionRequestId = request.id
                            self.sessionState.pendingPermission = TimelineEvent.permission(
                                requestId: request.id,
                                tool: request.toolName,
                                command: request.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
                                explanation: request.reason,
                                scope: "workspace",
                                agentMode: self.sessionState.agentMode
                            )
                        }
                    }
                }
            )

            let loop = AgentLoop(context: ctx)
            await loop.setEventHandler { [weak self] event in
                await MainActor.run { self?.handleAgentEvent(event) }
            }
            self.agentLoop = loop
            configuredModel = model
            sessionState.selectedModel = model
            addSystemEvent("Model: \(model.name) (\(model.provider))")
        } catch {
            if let configuredModel {
                sessionState.selectedModel = configuredModel
            }
            addErrorEvent("Failed to switch model: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Methods

    private func loadSessionHistory(_ session: Session) {
        // Load from persistence
        addSystemEvent("Loaded session: \(session.title)")
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

    // MARK: - Attachments

    public func addAttachment(_ attachment: Attachment) {
        sessionState.composerAttachments.append(attachment)
    }

    public func removeAttachment(_ attachment: Attachment) {
        sessionState.composerAttachments.removeAll { $0.id == attachment.id }
    }
    
    // MARK: - Permission Handling
    
    /// Called by UI when user responds to a permission request
    public func respondToPermission(requestId: String, decision: PermissionResponse.Decision) {
        if backendMode == .remote {
            guard let client = remoteClient, let sessionID = remotePermissionSessionID else {
                addErrorEvent("No remote permission request is pending")
                return
            }
            let response: String
            switch decision {
            case .allowOnce: response = "once"
            case .allowAlways: response = "always"
            case .deny: response = "reject"
            }
            sessionState.pendingPermission = nil
            remotePermissionSessionID = nil
            Task { [weak self] in
                do {
                    try await client.replyPermission(sessionID: sessionID, permissionID: requestId, response: response)
                    await MainActor.run { self?.addSystemEvent("Permission \(response)") }
                } catch {
                    await MainActor.run { self?.addErrorEvent("Permission reply failed: \(error.localizedDescription)") }
                }
            }
            return
        }

        guard requestId == pendingPermissionRequestId,
              let continuation = pendingPermissionContinuation else {
            addErrorEvent("Ignoring stale permission response \(requestId)")
            return
        }

        pendingPermissionContinuation = nil
        pendingPermissionRequestId = nil
        sessionState.pendingPermission = nil
        continuation.resume(returning: PermissionResponse(requestId: requestId, decision: decision))
        addSystemEvent("Permission \(decision.rawValue) for \(requestId)")
    }

    // MARK: - Remote OpenCode backend

    private func sendRemotePrompt(_ text: String) {
        guard let client = remoteClient, let sessionID = sessionState.currentSession?.id else {
            addErrorEvent("Remote OpenCode session is not ready")
            return
        }

        sessionState.addEvent(TimelineEvent.userPrompt(
            text,
            attachments: sessionState.composerAttachments,
            agentMode: sessionState.agentMode
        ))
        sessionState.composerAttachments.removeAll()
        sessionState.isProcessing = true

        runningTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.sendPromptAsync(
                    sessionID: sessionID,
                    text: text,
                    agent: self.sessionState.agentMode.rawValue.lowercased()
                )
            } catch is CancellationError {
                self.sessionState.isProcessing = false
                self.runningTask = nil
            } catch {
                self.sessionState.isProcessing = false
                self.runningTask = nil
                self.addErrorEvent("Remote prompt failed: \(error.localizedDescription)")
            }
        }
    }

    private func startRemoteEvents(_ client: OpenCodeRemoteClient) {
        remoteEventTask?.cancel()
        remoteEventTask = Task { [weak self] in
            do {
                let stream = await client.events()
                for try await event in stream {
                    guard !Task.isCancelled else { break }
                    await MainActor.run { self?.handleRemoteEvent(event) }
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self?.connectionStatus = "error: event stream disconnected Â· \(error.localizedDescription)"
                    self?.sessionState.isProcessing = false
                }
            }
        }
    }

    private func handleRemoteEvent(_ event: OpenCodeRemoteEvent) {
        switch event {
        case .connected:
            break
        case .part(let part):
            upsertRemotePart(part)
        case .permission(let permission):
            guard permission.sessionID == sessionState.currentSession?.id else { return }
            remotePermissionSessionID = permission.sessionID
            sessionState.pendingPermission = TimelineEvent.permission(
                requestId: permission.id,
                tool: permission.type,
                command: permission.metadata["command"] ?? permission.title,
                explanation: permission.title,
                scope: "remote workspace",
                agentMode: sessionState.agentMode
            )
        case .sessionIdle(let sessionID):
            guard sessionID == sessionState.currentSession?.id else { return }
            sessionState.isProcessing = false
            runningTask = nil
            addSuccessEvent("Done")
        case .sessionError(let message):
            sessionState.isProcessing = false
            runningTask = nil
            addErrorEvent(message)
        case .other:
            break
        }
    }

    private func upsertRemotePart(_ part: OpenCodeRemotePart) {
        switch part.kind {
        case .text:
            guard let text = part.text, !text.isEmpty else { return }
            if let timelineID = remotePartTimelineIDs[part.id],
               let index = sessionState.timelineEvents.firstIndex(where: { $0.id == timelineID }) {
                sessionState.timelineEvents[index].assistantText = text
            } else {
                let event = TimelineEvent.assistantText(text, agentMode: sessionState.agentMode)
                remotePartTimelineIDs[part.id] = event.id
                sessionState.addEvent(event)
            }

        case .reasoning:
            guard let text = part.text, !text.isEmpty else { return }
            if remotePartTimelineIDs[part.id] == nil {
                let event = TimelineEvent.system("thinking Â· \(text)")
                remotePartTimelineIDs[part.id] = event.id
                sessionState.addEvent(event)
            }

        case .tool:
            let eventID = part.callID ?? part.id
            let state: ToolCallState
            switch part.status {
            case "completed": state = .success
            case "error": state = .failed
            default: state = .running
            }
            if sessionState.timelineEvents.contains(where: { $0.id == eventID }) {
                sessionState.updateToolCall(
                    id: eventID,
                    state: state,
                    output: part.error ?? part.output,
                    duration: nil
                )
            } else {
                let event = TimelineEvent.toolCall(
                    id: eventID,
                    name: part.tool ?? "tool",
                    arguments: part.input,
                    state: state,
                    agentMode: sessionState.agentMode
                )
                sessionState.addEvent(event)
                if let output = part.error ?? part.output {
                    sessionState.updateToolCall(id: eventID, state: state, output: output, duration: nil)
                }
            }

        case .other:
            break
        }
    }

    private func loadRemoteHistory(sessionID: String) async {
        guard let client = remoteClient else { return }
        do {
            let messages = try await client.messages(sessionID: sessionID)
            await MainActor.run {
                self.sessionState.clearTimeline()
                self.remotePartTimelineIDs.removeAll()
                for message in messages {
                    for part in message.parts {
                        if message.role == "user", part.kind == .text, let text = part.text {
                            self.sessionState.addEvent(TimelineEvent.userPrompt(text, agentMode: self.sessionState.agentMode))
                        } else {
                            self.upsertRemotePart(part)
                        }
                    }
                }
            }
        } catch {
            await MainActor.run { self.addErrorEvent("Failed to load remote history: \(error.localizedDescription)") }
        }
    }

}

// MARK: - Preview Helper

extension SessionAdapter {
    static func preview() -> SessionAdapter {
        let adapter = SessionAdapter()
        adapter.backendMode = .native
        adapter.setupDemoProject()
        // Add demo timeline events
        adapter.sessionState.addEvent(TimelineEvent.userPrompt("Fix the provider picker", agentMode: .build))
        adapter.sessionState.addEvent(TimelineEvent.assistantText("I'll help you fix the provider picker. Let me first examine the current implementation.", agentMode: .build))
        adapter.sessionState.addEvent(TimelineEvent.toolCall(name: "Read", arguments: ["path": "Sources/UI/ProviderPickerView.swift"], state: .success, agentMode: .build))
        adapter.sessionState.addEvent(TimelineEvent.toolResult(name: "Read", output: "// ProviderPickerView.swift\n// ... file content", duration: 0.3, state: .success, agentMode: .build))
        adapter.sessionState.addEvent(TimelineEvent.assistantText("Now I can see the issue. The picker isn't properly handling the provider selection.", agentMode: .build))
        return adapter
    }
}
