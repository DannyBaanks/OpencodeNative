import Foundation
import SwiftUI

// MARK: - Session View Model Adapter

/// Bridges the existing SessionViewModel (TUI/console) with the new ActiveSessionState (iOS 27 workbench)
@MainActor
public final class SessionAdapter: ObservableObject {
    @Published public var sessionState = ActiveSessionState()
    @Published public var projects: [Project] = Project.demoProjects

    private var originalVM: SessionViewModel?
    private var agentLoop: AgentLoop?
    private var workspace: IOSWorkspace?
    private var persistence: IOSPersistence?
    private var modelProvider: (any ModelProvider)?
    private var toolExecutor: FileSystemToolExecutor?
    
    // Permission handling
    private var pendingPermissionContinuation: CheckedContinuation<PermissionResponse, Never>?

    public init() {
        setupDemoProject()
        Task { await initializeRuntime() }
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
        // Load session history
        loadSessionHistory(session)
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
                conversationId: UUID().uuidString,
                workspace: ws,
                persistence: ps,
                modelProvider: provider,
                toolExecutor: exec,
                systemPrompt: systemPromptText(),
                maxTurns: 12,
                permissionHandler: { [weak self] request in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor in
                            self?.pendingPermissionContinuation = continuation
                            self?.sessionState.pendingPermission = TimelineEvent.permission(
                                tool: request.toolName,
                                command: request.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
                                explanation: request.reason,
                                scope: "workspace",
                                agentMode: self?.sessionState.agentMode ?? .build
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

            sessionState.selectedModel = ModelInfo(
                name: "Demo Scripted",
                provider: "Local",
                providerIcon: "cpu",
                isLocal: true
            )

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
                    let args = call.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                    let event = TimelineEvent.toolCall(name: call.name, arguments: call.arguments, state: .running, agentMode: sessionState.agentMode)
                    sessionState.addEvent(event)
                }
            }

        case .toolResult(let result):
            if let error = result.error {
                sessionState.updateToolCall(id: findLatestToolCallId(), state: .failed, output: error, duration: 0)
                addErrorEvent("Tool error: \(error)")
            } else {
                sessionState.updateToolCall(id: findLatestToolCallId(), state: .success, output: result.output, duration: 1.0)
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

    private func findLatestToolCallId() -> String {
        sessionState.timelineEvents
            .last(where: { $0.kind == .toolCall })?.id ?? ""
    }

    // MARK: - User Input Handling

    public func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Add user message
        let userEvent = TimelineEvent.userPrompt(trimmed, attachments: sessionState.composerAttachments, agentMode: sessionState.agentMode)
        sessionState.addEvent(userEvent)
        sessionState.composerAttachments.removeAll()

        // Send to agent
        sessionState.isProcessing = true
        Task {
            do {
                _ = try await agentLoop?.run(userInput: trimmed)
                await MainActor.run { sessionState.isProcessing = false }
            } catch {
                await MainActor.run {
                    sessionState.isProcessing = false
                    addErrorEvent(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Agent Mode Switching

    public func setAgentMode(_ mode: AgentMode) {
        sessionState.agentMode = mode
        // In a real implementation, this might require reinitializing the agent loop
        addSystemEvent("Agent mode: \(mode.rawValue)")
    }

    // MARK: - Model Switching

    public func setModel(_ model: ModelInfo) {
        sessionState.selectedModel = model
        // Reinitialize with new model provider
        Task { await reinitializeWithModel(model) }
        addSystemEvent("Model: \(model.name) (\(model.provider))")
    }

    private func reinitializeWithModel(_ model: ModelInfo) async {
        do {
            // Keep existing workspace and persistence
            guard let ws = workspace, let ps = persistence else {
                await initializeRuntime()
                return
            }

            let provider: any ModelProvider
            if model.isLocal {
                provider = ScriptedModelProvider(script: ScriptedModelProvider.demoScript())
            } else {
                let remote = RemoteModelProvider()
                // Load API key from Keychain
                let apiKey = (try? await ps.loadAPIKey(provider: model.provider.lowercased())) ?? ""
                let baseURL = model.provider.lowercased() == "anthropic"
                    ? "https://api.anthropic.com/v1"
                    : "https://api.openai.com/v1"
                try await remote.configure(ModelConfiguration(apiKey: apiKey, baseURL: baseURL))
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
                toolExecutor: exec,
                systemPrompt: systemPromptText(),
                maxTurns: 12,
                permissionHandler: { [weak self] request in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor in
                            self?.pendingPermissionContinuation = continuation
                            self?.sessionState.pendingPermission = TimelineEvent.permission(
                                tool: request.toolName,
                                command: request.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
                                explanation: request.reason,
                                scope: "workspace",
                                agentMode: self?.sessionState.agentMode ?? .build
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
        } catch {
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
        var event = TimelineEvent.system(text)
        event.kind = .system
        sessionState.addEvent(event)
    }

    private func addSuccessEvent(_ text: String) {
        var event = TimelineEvent.system(text)
        event.kind = .system
        sessionState.addEvent(event)
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
        if let continuation = pendingPermissionContinuation {
            pendingPermissionContinuation = nil
            let response = PermissionResponse(requestId: requestId, decision: decision)
            continuation.resume(returning: response)
        }
        sessionState.pendingPermission = nil
        addSystemEvent("Permission \(decision.rawValue) for request \(requestId)")
    }
}

// MARK: - Preview Helper

extension SessionAdapter {
    static func preview() -> SessionAdapter {
        let adapter = SessionAdapter()
        // Add demo timeline events
        adapter.sessionState.addEvent(TimelineEvent.userPrompt("Fix the provider picker", agentMode: .build))
        adapter.sessionState.addEvent(TimelineEvent.assistantText("I'll help you fix the provider picker. Let me first examine the current implementation.", agentMode: .build))
        adapter.sessionState.addEvent(TimelineEvent.toolCall(name: "Read", arguments: ["path": "Sources/UI/ProviderPickerView.swift"], state: .success, agentMode: .build))
        adapter.sessionState.addEvent(TimelineEvent.toolResult(name: "Read", output: "// ProviderPickerView.swift\n// ... file content", duration: 0.3, state: .success, agentMode: .build))
        adapter.sessionState.addEvent(TimelineEvent.assistantText("Now I can see the issue. The picker isn't properly handling the provider selection.", agentMode: .build))
        return adapter
    }
}