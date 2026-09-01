import Foundation
import SwiftUI

@MainActor
public final class OpenCodeServerBackend: WorkbenchBackend {
    public var mode: BackendMode { .remote }
    
    private let client: OpenCodeRemoteClient
    private let pairing: OpenCodePairing
    private var eventTask: Task<Void, Never>?
    private var currentSessionIDStorage: String?
    private var connectionStatusStorage = "connected"
    
    private var eventContinuation: AsyncStream<WorkbenchEvent>.Continuation?
    public let eventStream: AsyncStream<WorkbenchEvent>
    
    private let eventQueue: AsyncStream<WorkbenchEvent>
    
    public init(pairing: OpenCodePairing) {
        self.pairing = pairing
        self.client = OpenCodeRemoteClient(pairing: pairing)
        
        var continuation: AsyncStream<WorkbenchEvent>.Continuation?
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
        self.eventQueue = eventStream
    }
    
    public var connectionStatus: String {
        get async { connectionStatusStorage }
    }
    
    public var currentSessionID: String? {
        get async { currentSessionIDStorage }
    }
    
    public func connectRemote(pairing: OpenCodePairing) async throws {
        let health = try await client.health()
        guard health.healthy else { throw OpenCodeRemoteError.invalidResponse }
        
        var sessions = try await client.listSessions()
        if sessions.isEmpty {
            sessions = [try await client.createSession(title: "OpencodeNative")]
        }
        
        if let first = sessions.first {
            currentSessionIDStorage = first.id
            await loadHistory(sessionID: first.id)
        }
        
        connectionStatusStorage = "connected · OpenCode \(health.version) · \(pairing.host):\(pairing.port)"
        try await startEventStream()
        
        eventContinuation?.yield(.connected)
    }
    
    public func disconnect() async {
        await stopEventStream()
        currentSessionIDStorage = nil
        connectionStatusStorage = ""
        eventContinuation?.yield(.disconnected("User disconnected"))
        eventContinuation?.finish()
    }
    
    public func useNativeRuntime() async throws {
        throw WorkbenchError.unsupportedFeature("Native mode requires different backend")
    }
    
    public func listProjects() async throws -> [Project] {
        let path = try await client.getPath()
        let project = Project(
            id: "remote:\(pairing.host):\(pairing.port)",
            name: "OpenCode @ \(pairing.host)",
            path: pairing.directory.isEmpty ? path : pairing.directory,
            avatarColor: .white,
            sessionCount: 0
        )
        return [project]
    }
    
    public func listSessions(projectID: String) async throws -> [Session] {
        let remoteSessions = try await client.listSessions()
        return remoteSessions.map { remote in
            Session(
                id: remote.id,
                projectId: projectID,
                title: remote.title,
                lastEventSummary: "OpenCode remote session",
                timestamp: remote.updatedAt,
                agentMode: .build,
                isRunning: false
            )
        }
    }
    
    public func createSession(projectID: String, title: String) async throws -> Session {
        let remote = try await client.createSession(title: title)
        let session = Session(
            id: remote.id,
            projectId: projectID,
            title: remote.title,
            lastEventSummary: "New session",
            timestamp: remote.updatedAt,
            agentMode: .build,
            isRunning: false
        )
        currentSessionIDStorage = remote.id
        await loadHistory(sessionID: remote.id)
        eventContinuation?.yield(.sessionsChanged)
        return session
    }
    
    public func renameSession(sessionID: String, title: String) async throws {
        try await client.renameSession(sessionID: sessionID, title: title)
        eventContinuation?.yield(.sessionsChanged)
    }
    
    public func deleteSession(sessionID: String) async throws {
        try await client.deleteSession(sessionID: sessionID)
        if currentSessionIDStorage == sessionID {
            currentSessionIDStorage = nil
        }
        eventContinuation?.yield(.sessionsChanged)
    }
    
    public func selectSession(_ sessionID: String) async throws {
        currentSessionIDStorage = sessionID
        await loadHistory(sessionID: sessionID)
    }
    
    public func sendPrompt(_ text: String, agent: String?, model: ModelInfo?) async throws {
        let provider = model?.provider
        let modelID = model?.apiModelId
        
        if let provider, let modelID {
            try await client.sendPromptAsyncWithModel(
                sessionID: currentSessionIDStorage!,
                text: text,
                agent: agent,
                modelProvider: provider,
                modelID: modelID
            )
        } else {
            try await client.sendPromptAsync(
                sessionID: currentSessionIDStorage!,
                text: text,
                agent: agent
            )
        }
    }
    
    public func abort() async throws {
        guard let sessionID = currentSessionIDStorage else { return }
        try await client.abort(sessionID: sessionID)
    }
    
    public func replyPermission(requestID: String, decision: PermissionResponse.Decision) async throws {
        guard let sessionID = currentSessionIDStorage else { return }
        let response: String
        switch decision {
        case .allowOnce: response = "once"
        case .allowAlways: response = "always"
        case .deny: response = "reject"
        }
        try await client.replyPermission(sessionID: sessionID, permissionID: requestID, response: response)
    }
    
    public func loadHistory(sessionID: String) async throws {
        let messages = try await client.messages(sessionID: sessionID)
        // Events will be yielded via event stream when connected
    }
    
    public func startEventStream() async throws {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await self.client.events()
                for try await event in stream {
                    try Task.checkCancellation()
                    await self.handleRemoteEvent(event)
                }
            } catch is CancellationError {
                return
            } catch {
                await self.handleEventError(error)
            }
        }
    }
    
    public func stopEventStream() async {
        eventTask?.cancel()
        eventTask = nil
    }
    
    public func listFiles(path: String) async throws -> [WorkbenchFileNode] {
        let remoteFiles = try await client.listFiles(path: path)
        return remoteFiles.map { rf in
            WorkbenchFileNode(
                id: UUID().uuidString,
                name: rf.name,
                path: rf.path,
                isDirectory: rf.isDirectory,
                status: rf.ignored == true ? "ignored" : nil
            )
        }
    }
    
    public func fileContent(path: String) async throws -> WorkbenchFileContent {
        let remote = try await client.fileContent(path: path)
        return WorkbenchFileContent(
            path: remote.path,
            content: remote.content,
            mimeType: remote.mimeType,
            encoding: remote.encoding
        )
    }
    
    public func sessionDiff(sessionID: String) async throws -> [SessionDiffFile] {
        let diffs = try await client.sessionDiff(sessionID: sessionID)
        return diffs.map { d in
            SessionDiffFile(
                id: UUID().uuidString,
                path: d.file,
                additions: d.additions,
                deletions: d.deletions,
                before: d.before,
                after: d.after
            )
        }
    }
    
    public func runShell(command: String, agent: String?) async throws -> ShellResult {
        guard let sessionID = currentSessionIDStorage else { throw WorkbenchError.noSession }
        let result = try await client.runShell(sessionID: sessionID, command: command, agent: agent)
        let textParts = result.parts.compactMap { $0.text }
        let toolParts = result.parts.compactMap { part -> (String, String)? in
            if let tool = part.tool, let output = part.output { return (tool, output) }
            return nil
        }
        let error = result.parts.first { $0.kind == .tool && $0.status == "error" }?.error
        return ShellResult(
            sessionID: result.sessionID,
            messageID: result.messageID,
            textParts: textParts,
            toolParts: Dictionary(uniqueKeysWithValues: toolParts),
            error: error
        )
    }
    
    public func availableProviders() async throws -> ProviderListResult {
        let result = try await client.providers()
        return ProviderListResult(
            all: result.all.map { ProviderInfo(id: $0.id, name: $0.name, models: $0.models) },
            connected: result.connected,
            defaultProvider: result.`default`
        )
    }
    
    public func config() async throws -> ConfigInfo {
        try await client.config()
    }
    
    public func availableCommands() async throws -> [CommandInfo] {
        let cmds = try await client.commands()
        return cmds.map { CommandInfo(name: $0.name, description: $0.description) }
    }
    
    public func sendWorkbenchEvent(_ event: WorkbenchEvent) {
        eventContinuation?.yield(event)
    }
    
    private func handleRemoteEvent(_ event: OpenCodeRemoteEvent) async {
        switch event {
        case .connected:
            eventContinuation?.yield(.connected)
        case .part(let part):
            eventContinuation?.yield(.partUpdated(
                partID: part.id,
                kind: String(describing: part.kind),
                text: part.text,
                tool: part.tool,
                callID: part.callID,
                status: part.status,
                input: part.input,
                output: part.output,
                error: part.error
            ))
        case .permission(let perm):
            eventContinuation?.yield(.permissionAsked(
                requestID: perm.id,
                sessionID: perm.sessionID,
                tool: perm.type,
                command: perm.metadata["command"] ?? perm.title,
                explanation: perm.title
            ))
        case .sessionIdle(let sessionID):
            eventContinuation?.yield(.sessionIdle(sessionID))
        case .sessionError(let msg):
            eventContinuation?.yield(.sessionError(msg))
        case .other:
            break
        }
    }
    
    private func handleEventError(_ error: Error) async {
        connectionStatusStorage = "error: \(error.localizedDescription)"
        eventContinuation?.yield(.sessionError(error.localizedDescription))
    }
}

public enum WorkbenchError: Error, LocalizedError, Sendable {
    case unsupportedFeature(String)
    case noSession
    case notConnected
    
    public var errorDescription: String? {
        switch self {
        case .unsupportedFeature(let f): return "Unsupported feature: \(f)"
        case .noSession: return "No session selected"
        case .notConnected: return "Not connected to backend"
        }
    }
}