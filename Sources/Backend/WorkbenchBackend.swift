import Foundation
import SwiftUI

public enum BackendMode: String, Sendable {
    case unconfigured
    case native
    case remote
}

public struct WorkbenchFileNode: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date
    public let status: String?
    
    public init(id: String = UUID().uuidString, name: String, path: String, isDirectory: Bool, size: Int64 = 0, modifiedAt: Date = Date(), status: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.status = status
    }
}

public struct WorkbenchFileContent: Sendable {
    public let path: String
    public let content: String
    public let mimeType: String?
    public let encoding: String?
}

public struct SessionDiffFile: Sendable, Identifiable {
    public let id: String
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let before: String?
    public let after: String?
    
    public init(id: String = UUID().uuidString, path: String, additions: Int, deletions: Int, before: String? = nil, after: String? = nil) {
        self.id = id
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.before = before
        self.after = after
    }
}

public struct ShellResult: Sendable {
    public let sessionID: String
    public let messageID: String
    public let textParts: [String]
    public let toolParts: [String: String]
    public let error: String?
}

public struct ProviderInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let models: [String: [String: Any]]?
    
    public init(id: String, name: String, models: [String: [String: Any]]? = nil) {
        self.id = id
        self.name = name
        self.models = models
    }
}

public struct ProviderListResult: Sendable {
    public let all: [ProviderInfo]
    public let connected: [String]
    public let defaultProvider: String?
}

public struct ConfigInfo: Sendable {
    public let agents: [String: [String: Any]]?
    public let provider: [String: Any]?
}

public struct CommandInfo: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    
    public init(id: String = UUID().uuidString, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public enum WorkbenchEvent: Sendable {
    case connected
    case disconnected(String?)
    case partUpdated(partID: String, kind: String, text: String?, tool: String?, callID: String?, status: String?, input: [String: String], output: String?, error: String?)
    case permissionAsked(requestID: String, sessionID: String, tool: String, command: String, explanation: String)
    case sessionIdle(sessionID: String)
    case sessionError(String)
    case sessionsChanged
    case filesChanged
    case agentModeChanged(AgentMode)
    case modelChanged(ModelInfo?)
}

public protocol WorkbenchBackend: Actor {
    var mode: BackendMode { get }
    var connectionStatus: String { get async }
    var currentSessionID: String? { get async }
    
    func connectRemote(pairing: OpenCodePairing) async throws
    func disconnect() async
    func useNativeRuntime() async throws
    
    func listProjects() async throws -> [Project]
    func listSessions(projectID: String) async throws -> [Session]
    func createSession(projectID: String, title: String) async throws -> Session
    func renameSession(sessionID: String, title: String) async throws
    func deleteSession(sessionID: String) async throws
    func selectSession(_ sessionID: String) async throws
    
    func sendPrompt(_ text: String, agent: String?, model: ModelInfo?) async throws
    func abort() async throws
    
    func replyPermission(requestID: String, decision: PermissionResponse.Decision) async throws
    
    func loadHistory(sessionID: String) async throws
    func startEventStream() async throws
    func stopEventStream() async
    
    func listFiles(path: String) async throws -> [WorkbenchFileNode]
    func fileContent(path: String) async throws -> WorkbenchFileContent
    func sessionDiff(sessionID: String) async throws -> [SessionDiffFile]
    func runShell(command: String, agent: String?) async throws -> ShellResult
    
    func availableProviders() async throws -> ProviderListResult
    func config() async throws -> ConfigInfo
    func availableCommands() async throws -> [CommandInfo]
    
    func sendWorkbenchEvent(_ event: WorkbenchEvent)
}