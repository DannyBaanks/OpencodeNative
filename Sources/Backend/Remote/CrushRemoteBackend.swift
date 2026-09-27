import Foundation

/// Crush remote backend (STUB - not yet implemented).
/// Track: https://github.com/charmbracelet/crush
@MainActor
public final class CrushRemoteBackend: WorkbenchBackend, RemoteBackend {
    public var mode: BackendMode { .remote }
    public let remoteType: RemoteBackendType = .crush
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

    private static let unsupported = RemoteBackendError
        .unsupportedFeature("Crush remote backend not yet implemented")

    // MARK: - RemoteBackend

    public func configure(with pairing: RemotePairing) async throws { throw Self.unsupported }
    public func healthCheck() async throws -> RemoteHealth { throw Self.unsupported }
    public func listSessions() async throws -> [RemoteSession] { throw Self.unsupported }
    public func createSession(title: String) async throws -> RemoteSession { throw Self.unsupported }
    public func deleteSession(sessionID: String) async throws { throw Self.unsupported }
    public func renameSession(sessionID: String, title: String) async throws { throw Self.unsupported }
    public func sendPrompt(sessionID: String, text: String, agent: String?, modelProvider: String?, modelID: String?) async throws { throw Self.unsupported }
    public func abort(sessionID: String) async throws { throw Self.unsupported }
    public func replyPermission(sessionID: String, permissionID: String, response: String) async throws { throw Self.unsupported }
    public func messages(sessionID: String) async throws -> [RemoteMessage] { throw Self.unsupported }

    public func events() -> AsyncThrowingStream<RemoteEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: Self.unsupported)
        }
    }

    public func listFiles(path: String) async throws -> [RemoteFileNode] { throw Self.unsupported }
    public func fileContent(path: String) async throws -> RemoteFileContent { throw Self.unsupported }
    public func runShell(sessionID: String, command: String, agent: String?, workdir: String?) async throws -> ShellResult { throw Self.unsupported }
    public func sessionDiff(sessionID: String) async throws -> [SessionDiff] { throw Self.unsupported }
    public func providers() async throws -> ProviderListResult { throw Self.unsupported }
    public func config() async throws -> ConfigInfo { throw Self.unsupported }
    public func commands() async throws -> [CommandInfo] { throw Self.unsupported }
    public func getPath() async throws -> String { throw Self.unsupported }

    // MARK: - WorkbenchBackend

    public func connectRemote(pairing: RemotePairing) async throws { throw Self.unsupported }
    public func disconnect() async {}
    public func useNativeRuntime() async throws { throw WorkbenchError.unsupportedFeature("Native mode requires different backend") }
    public func listProjects() async throws -> [Project] { throw Self.unsupported }
    public func listSessions(projectID: String) async throws -> [Session] { throw Self.unsupported }
    public func createSession(projectID: String, title: String) async throws -> Session { throw Self.unsupported }
    public func renameSession(sessionID: String, title: String) async throws { throw Self.unsupported }
    public func deleteSession(sessionID: String) async throws { throw Self.unsupported }
    public func selectSession(_ sessionID: String) async throws { throw Self.unsupported }
    public func sendPrompt(_ text: String, agent: String?, model: ModelInfo?) async throws { throw Self.unsupported }
    public func abort() async throws { throw Self.unsupported }
    public func replyPermission(requestID: String, decision: PermissionResponse.Decision) async throws { throw Self.unsupported }
    public func loadHistory(sessionID: String) async throws -> [TimelineEvent] { throw Self.unsupported }
    public func startEventStream() async throws { throw Self.unsupported }
    public func stopEventStream() async {}
    public func listFiles(path: String) async throws -> [WorkbenchFileNode] { throw Self.unsupported }
    public func fileContent(path: String) async throws -> WorkbenchFileContent { throw Self.unsupported }
    public func sessionDiff(sessionID: String) async throws -> [SessionDiffFile] { throw Self.unsupported }
    public func runShell(command: String, agent: String?) async throws -> ShellResult { throw Self.unsupported }
    public func availableProviders() async throws -> ProviderListResult { throw Self.unsupported }
    public func config() async throws -> ConfigInfo { throw Self.unsupported }
    public func availableCommands() async throws -> [CommandInfo] { throw Self.unsupported }
    public func sendWorkbenchEvent(_ event: WorkbenchEvent) {}
}