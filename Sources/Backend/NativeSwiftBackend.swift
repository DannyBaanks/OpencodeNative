import Foundation
import SwiftUI

@MainActor
public final class NativeSwiftBackend: WorkbenchBackend {
    public var mode: BackendMode { .native }
    
    private var workspace: IOSWorkspace?
    var persistence: IOSPersistence?
    private var agentLoop: AgentLoop?
    private var modelProvider: (any ModelProvider)?
    private var toolExecutor: FileSystemToolExecutor?
    private let conversationId = UUID().uuidString
    private var runningTask: Task<Void, Never>?
    private var connectionStatusStorage = "native runtime"
    private var currentSessionIDStorage: String?
    private var eventContinuation: AsyncStream<WorkbenchEvent>.Continuation?
    public let eventStream: AsyncStream<WorkbenchEvent>
    
    public init() {
        var cont: AsyncStream<WorkbenchEvent>.Continuation?
        self.eventStream = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }
    
    public var connectionStatus: String {
        get async { connectionStatusStorage }
    }
    
    public var currentSessionID: String? {
        get async { currentSessionIDStorage }
    }
    
    public func connectRemote(pairing: OpenCodePairing) async throws {
        throw WorkbenchError.unsupportedFeature("Native backend doesn't support remote connection")
    }
    
    public func disconnect() async {
        runningTask?.cancel()
        runningTask = nil
        agentLoop = nil
        modelProvider = nil
        toolExecutor = nil
        workspace = nil
        persistence = nil
        currentSessionIDStorage = nil
        connectionStatusStorage = ""
        eventContinuation?.yield(.disconnected("Native runtime stopped"))
        eventContinuation?.finish()
    }
    
    public func useNativeRuntime() async throws {
        guard workspace == nil else { return }
        
        do {
            let ws = try IOSWorkspace()
            let ps = try IOSPersistence()
            self.workspace = ws
            self.persistence = ps
            
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
                            self.eventContinuation?.yield(.permissionAsked(
                                requestID: request.id,
                                sessionID: self.conversationId,
                                tool: request.toolName,
                                command: request.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
                                explanation: request.reason
                            ))
                            self.eventContinuation?.yield(.connected)
                            continuation.resume(returning: PermissionResponse(requestId: request.id, decision: .allowAlways))
                        }
                    }
                }
            )
            
            let loop = AgentLoop(context: ctx)
            await loop.setEventHandler { [weak self] event in
                await self?.handleAgentEvent(event)
            }
            self.agentLoop = loop
            self.currentSessionIDStorage = self.conversationId
            
            connectionStatusStorage = "native runtime · sandbox: \(ws.rootURL.path)"
            eventContinuation?.yield(.connected)
        } catch {
            connectionStatusStorage = "error: \(error.localizedDescription)"
            throw error
        }
    }
    
    private func systemPromptText() -> String {
        """
        You are an assistant in OpenCodeNative, a native iOS workbench for OpenCode.
        You operate within the iOS sandbox with filesystem tools.
        Be concise and technical. Use tools to accomplish tasks.
        """
    }
    
    public func listProjects() async throws -> [Project] {
        guard let ws = workspace else { throw WorkbenchError.notConnected }
        let project = Project(
            id: "native:\(ws.rootURL.lastPathComponent)",
            name: "iOS Sandbox",
            path: ws.rootURL.path,
            avatarColor: .blue,
            sessionCount: 0
        )
        return [project]
    }
    
    public func listSessions(projectID: String) async throws -> [Session] {
        guard let ps = persistence else { throw WorkbenchError.notConnected }
        let convs = try await ps.listConversations()
        return convs.map { c in
            Session(
                id: c.id,
                projectId: projectID,
                title: c.title,
                lastEventSummary: c.lastMessagePreview ?? "No messages",
                timestamp: c.updatedAt,
                agentMode: .build,
                isRunning: false
            )
        }
    }
    
    public func createSession(projectID: String, title: String) async throws -> Session {
        guard let ps = persistence else { throw WorkbenchError.notConnected }
        let conv = Conversation(title: title.isEmpty ? "New Session" : title)
        try await ps.saveConversation(conv)
        currentSessionIDStorage = conv.id
        eventContinuation?.yield(.sessionsChanged)
        return Session(id: conv.id, projectId: projectID, title: conv.title, lastEventSummary: "New session", timestamp: conv.updatedAt, agentMode: .build, isRunning: false)
    }
    
    public func renameSession(sessionID: String, title: String) async throws {
        guard let ps = persistence else { throw WorkbenchError.notConnected }
        if var conv = try await ps.loadConversation(id: sessionID) {
            conv.title = title
            try await ps.saveConversation(conv)
            eventContinuation?.yield(.sessionsChanged)
        }
    }
    
    public func deleteSession(sessionID: String) async throws {
        guard let ps = persistence else { throw WorkbenchError.notConnected }
        try await ps.deleteConversation(id: sessionID)
        if currentSessionIDStorage == sessionID {
            currentSessionIDStorage = nil
        }
        eventContinuation?.yield(.sessionsChanged)
    }
    
    public func selectSession(_ sessionID: String) async throws {
        currentSessionIDStorage = sessionID
        guard let ps = persistence else { throw WorkbenchError.notConnected }
        if let conv = try await ps.loadConversation(id: sessionID) {
            eventContinuation?.yield(.partUpdated(partID: UUID().uuidString, kind: "system", text: "Loaded session: \(conv.title)", tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil))
        }
    }
    
    public func sendPrompt(_ text: String, agent: String?, model: ModelInfo?) async throws {
        guard let loop = agentLoop else {
            throw WorkbenchError.unsupportedFeature("Agent runtime not initialized")
        }
        
        eventContinuation?.yield(.partUpdated(partID: UUID().uuidString, kind: "userPrompt", text: text, tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil))
        
        runningTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await loop.run(userInput: text)
                guard !Task.isCancelled else { throw CancellationError() }
                self.eventContinuation?.yield(.sessionIdle(self.conversationId))
            } catch is CancellationError {
                self.eventContinuation?.yield(.sessionError("Stopped"))
            } catch {
                self.eventContinuation?.yield(.sessionError(error.localizedDescription))
            }
        }
    }
    
    public func abort() async throws {
        runningTask?.cancel()
        runningTask = nil
        eventContinuation?.yield(.sessionError("Stopped"))
    }
    
    public func replyPermission(requestID: String, decision: PermissionResponse.Decision) async throws {
        // Native permissions handled via AgentLoop continuation; already resolved in handler
    }
    
    public func loadHistory(sessionID: String) async throws {
        // Already handled via eventContinuation in selectSession
    }
    
    public func startEventStream() async throws {
        // AgentLoop events are already pushed via event handler
    }
    
    public func stopEventStream() async {
        // No separate stream
    }
    
    public func listFiles(path: String) async throws -> [WorkbenchFileNode] {
        guard let ws = workspace else { throw WorkbenchError.notConnected }
        let items = try await ws.listDirectory(at: path)
        return items.map { item in
            WorkbenchFileNode(
                id: UUID().uuidString,
                name: item.name,
                path: item.path,
                isDirectory: item.isDirectory,
                size: item.size,
                modifiedAt: item.modificationDate
            )
        }
    }
    
    public func fileContent(path: String) async throws -> WorkbenchFileContent {
        guard let ws = workspace else { throw WorkbenchError.notConnected }
        let data = try await ws.readFile(at: path)
        return WorkbenchFileContent(path: path, content: String(data: data, encoding: .utf8) ?? "", mimeType: nil, encoding: "utf-8")
    }
    
    public func sessionDiff(sessionID: String) async throws -> [SessionDiffFile] {
        throw WorkbenchError.unsupportedFeature("Diff requires remote OpenCode server")
    }
    
    public func runShell(command: String, agent: String?) async throws -> ShellResult {
        throw WorkbenchError.unsupportedFeature("Shell requires remote OpenCode server")
    }
    
    public func availableProviders() async throws -> ProviderListResult {
        let scripted = ScriptedModelProvider(script: ScriptedModelProvider.demoScript())
        return ProviderListResult(
            all: [ProviderInfo(id: "scripted", name: "Scripted Demo", models: ["scripted-1": [:]])],
            connected: ["scripted"],
            defaultProvider: "scripted"
        )
    }
    
    public func config() async throws -> ConfigInfo {
        return ConfigInfo(agents: ["build": [:], "plan": [:], "explore": [:], "review": [:], "custom": [:]], provider: nil)
    }
    
    public func availableCommands() async throws -> [CommandInfo] {
        return []
    }
    
    public func sendWorkbenchEvent(_ event: WorkbenchEvent) {
        eventContinuation?.yield(event)
    }
    
    private func handleAgentEvent(_ event: AgentLoopEvent) async {
        switch event {
        case .turnStarted(let turn):
            eventContinuation?.yield(.partUpdated(partID: UUID().uuidString, kind: "system", text: "— turn \(turn) —", tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil))
            
        case .modelResponse(let response):
            if !response.content.isEmpty {
                eventContinuation?.yield(.partUpdated(partID: UUID().uuidString, kind: "text", text: response.content, tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil))
            }
            if let calls = response.toolCalls, !calls.isEmpty {
                for call in calls {
                    eventContinuation?.yield(.partUpdated(partID: call.id, kind: "tool", text: nil, tool: call.name, callID: call.id, status: "running", input: call.arguments, output: nil, error: nil))
                }
            }
            
        case .toolResult(let result):
            let state: String
            switch result.error {
            case nil: state = "completed"
            default: state = "error"
            }
            eventContinuation?.yield(.partUpdated(
                partID: result.toolCallId,
                kind: "tool",
                text: nil,
                tool: nil,
                callID: result.toolCallId,
                status: state,
                input: [:],
                output: result.output,
                error: result.error
            ))
            
        case .error(let error):
            eventContinuation?.yield(.sessionError(error.localizedDescription))
            
        case .finished:
            eventContinuation?.yield(.sessionIdle(conversationId))
            
        default:
            break
        }
    }
}