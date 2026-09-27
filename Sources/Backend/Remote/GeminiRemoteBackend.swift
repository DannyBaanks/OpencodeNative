import Foundation

/// Gemini remote backend (STUB - not yet implemented).
/// Track: https://github.com/google-gemini/gemini-cli (gemini-cli server mode)
@MainActor
public final class GeminiRemoteBackend: WorkbenchBackend, RemoteBackend {
    public var mode: BackendMode { .remote }
    public let remoteType: RemoteBackendType = .gemini
    public var baseURL: URL { URL(string: "http://localhost:4096")! }
    public var authHeaders: [String: String] { [:] }

    private var eventContinuation: AsyncStream<WorkbenchEvent>.Continuation?
    public let eventStream: AsyncStream<WorkbenchEvent>

    public init() {
        var continuation: AsyncStream<WorkbenchEvent>.Continuation?
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    public var connectionStatus: String { get async { "not implemented" } }
    public var currentSessionID: String? { get async { nil } }

    // MARK: - RemoteBackend

    public func configure(with pairing: RemotePairing) async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func healthCheck() async throws -> RemoteHealth {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func listSessions() async throws -> [RemoteSession] {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func createSession(title: String) async throws -> RemoteSession {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func deleteSession(sessionID: String) async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func renameSession(sessionID: String, title: String) async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func sendPrompt(sessionID: String, text: String, agent: String?, modelProvider: String?, modelID: String?) async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func abort(sessionID: String) async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func replyPermission(sessionID: String, permissionID: String, response: String) async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func messages(sessionID: String) async throws -> [RemoteMessage] {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func events() -> AsyncThrowingStream<RemoteEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented"))
        }
    }

    public func listFiles(path: String) async throws -> [RemoteFileNode] {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func fileContent(path: String) async throws -> RemoteFileContent {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func runShell(sessionID: String, command: String, agent: String?, workdir: String?) async throws -> ShellResult {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func sessionDiff(sessionID: String) async throws -> [SessionDiff] {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func providers() async throws -> ProviderListResult {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func config() async throws -> ConfigInfo {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func commands() async throws -> [CommandInfo] {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func getPath() async throws -> String {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    // MARK: - WorkbenchBackend

    public func connectRemote(pairing: BackendPairing) async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func disconnect() async {}

    public func useNativeRuntime() async throws {
        throw WorkbenchError.unsupportedFeature("Native mode requires different backend")
    }

    public func listProjects() async throws -> [Project] {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func listSessions(projectID: String) async throws -> [Session] {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func createSession(projectID: String, title: String) async throws -> Session {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func selectSession(_ sessionID: String) async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func sendPrompt(_ text: String, agent: String?, model: ModelInfo?) async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func abort() async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func replyPermission(requestID: String, decision: PermissionResponse.Decision) async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func loadHistory(sessionID: String) async throws -> [TimelineEvent] {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func startEventStream() async throws {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func stopEventStream() async {}

    public func listFiles(path: String) async throws -> [WorkbenchFileNode] {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func fileContent(path: String) async throws -> WorkbenchFileContent {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func sessionDiff(sessionID: String) async throws -> [SessionDiffFile] {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func runShell(command: String, agent: String?) async throws -> ShellResult {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func availableProviders() async throws -> ProviderListResult {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func availableCommands() async throws -> [CommandInfo] {
        throw RemoteBackendError.unsupportedFeature("Gemini remote backend not yet implemented")
    }

    public func sendWorkbenchEvent(_ event: WorkbenchEvent) {}
}
