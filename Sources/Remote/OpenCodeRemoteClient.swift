import Foundation

public enum OpenCodeRemoteError: Error, LocalizedError, Sendable {
    case invalidPairingLink
    case invalidResponse
    case http(Int, String)
    case missingSession

    public var errorDescription: String? {
        switch self {
        case .invalidPairingLink: return "Invalid OpenCodeNative pairing link"
        case .invalidResponse: return "Invalid response from OpenCode server"
        case .http(let status, let body): return "OpenCode server HTTP \(status): \(body)"
        case .missingSession: return "No OpenCode session is selected"
        }
    }
}

public struct OpenCodePairing: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let directory: String

    public init(host: String, port: Int, username: String = "opencode", password: String, directory: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.directory = directory
    }

    public static func parse(_ raw: String) throws -> OpenCodePairing {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              components.scheme == "opencodenative",
              components.host == "pair" else {
            throw OpenCodeRemoteError.invalidPairingLink
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        guard let host = items["host"], !host.isEmpty,
              let portText = items["port"], let port = Int(portText),
              let password = items["password"], !password.isEmpty else {
            throw OpenCodeRemoteError.invalidPairingLink
        }
        return OpenCodePairing(
            host: host,
            port: port,
            username: items["username"] ?? "opencode",
            password: password,
            directory: items["directory"] ?? ""
        )
    }

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }
    
    public var rawValue: String {
        var components = URLComponents()
        components.scheme = "opencodenative"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        if !directory.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "directory", value: directory))
        }
        return components.url?.absoluteString ?? ""
    }
}

public struct OpenCodeRemoteHealth: Sendable {
    public let healthy: Bool
    public let version: String
}

public struct OpenCodeRemoteSession: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let directory: String
    public let updatedAt: Date
}

public struct OpenCodeRemotePart: Sendable {
    public enum Kind: Sendable { case text, reasoning, tool, other }
    public let id: String
    public let kind: Kind
    public let text: String?
    public let tool: String?
    public let callID: String?
    public let status: String?
    public let input: [String: String]
    public let output: String?
    public let error: String?
}

public struct OpenCodeRemoteMessage: Sendable {
    public let role: String
    public let id: String
    public let parts: [OpenCodeRemotePart]
}

public struct OpenCodeRemotePermission: Sendable {
    public let id: String
    public let sessionID: String
    public let title: String
    public let type: String
    public let metadata: [String: String]
}

public enum OpenCodeRemoteEvent: Sendable {
    case part(OpenCodeRemotePart)
    case permission(OpenCodeRemotePermission)
    case sessionIdle(String)
    case sessionError(String)
    case connected
    case other(String)
}

public actor OpenCodeRemoteClient {
    public let pairing: OpenCodePairing
    private let session: URLSession

    public init(pairing: OpenCodePairing, session: URLSession = .shared) {
        self.pairing = pairing
        self.session = session
    }

    public func health() async throws -> OpenCodeRemoteHealth {
        let data = try await request(path: "/global/health")
        let json = try jsonObject(data)
        return OpenCodeRemoteHealth(
            healthy: json["healthy"] as? Bool ?? false,
            version: json["version"] as? String ?? "unknown"
        )
    }

    public func listSessions() async throws -> [OpenCodeRemoteSession] {
        let data = try await request(path: "/session")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OpenCodeRemoteError.invalidResponse
        }
        return array.compactMap(Self.parseSession)
    }

    public func createSession(title: String? = nil) async throws -> OpenCodeRemoteSession {
        var body: [String: Any] = [:]
        if let title, !title.isEmpty { body["title"] = title }
        let data = try await request(path: "/session", method: "POST", jsonBody: body)
        let json = try jsonObject(data)
        guard let result = Self.parseSession(json) else { throw OpenCodeRemoteError.invalidResponse }
        return result
    }

    public func messages(sessionID: String) async throws -> [OpenCodeRemoteMessage] {
        let data = try await request(path: "/session/\(sessionID)/message")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OpenCodeRemoteError.invalidResponse
        }
        return array.compactMap(Self.parseMessage)
    }

    public func sendPromptAsync(sessionID: String, text: String, agent: String? = nil) async throws {
        var body: [String: Any] = [
            "parts": [["type": "text", "text": text]]
        ]
        if let agent, !agent.isEmpty { body["agent"] = agent }
        _ = try await request(path: "/session/\(sessionID)/prompt_async", method: "POST", jsonBody: body)
    }

    public func abort(sessionID: String) async throws {
        _ = try await request(path: "/session/\(sessionID)/abort", method: "POST", jsonBody: [:])
    }

    public func replyPermission(sessionID: String, permissionID: String, response: String) async throws {
        _ = try await request(
            path: "/session/\(sessionID)/permissions/\(permissionID)",
            method: "POST",
            jsonBody: ["response": response]
        )
    }

    public func events() -> AsyncThrowingStream<OpenCodeRemoteEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = makeRequest(path: "/event", method: "GET", jsonBody: nil)
                    let (bytes, response) = try await session.bytes(for: request)
                    try validate(response: response, data: Data())
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                let payload = dataLines.joined(separator: "\n")
                                dataLines.removeAll(keepingCapacity: true)
                                if let data = payload.data(using: .utf8), let event = Self.parseEvent(data) {
                                    continuation.yield(event)
                                }
                            }
                            continue
                        }
                        if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated func request(path: String, method: String = "GET", jsonBody: [String: Any]? = nil) async throws -> Data {
        let request = makeRequest(path: path, method: method, jsonBody: jsonBody)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private nonisolated func makeRequest(path: String, method: String, jsonBody: [String: Any]?) -> URLRequest {
        var components = URLComponents(url: pairing.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 90
        let credentials = Data("\(pairing.username):\(pairing.password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !pairing.directory.isEmpty {
            request.setValue(pairing.directory, forHTTPHeaderField: "x-opencode-directory")
        }
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        }
        return request
    }

    private nonisolated func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenCodeRemoteError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw OpenCodeRemoteError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenCodeRemoteError.invalidResponse
        }
        return json
    }

    private static func parseSession(_ json: [String: Any]) -> OpenCodeRemoteSession? {
        guard let id = json["id"] as? String else { return nil }
        let time = json["time"] as? [String: Any]
        let millis = (time?["updated"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        return OpenCodeRemoteSession(
            id: id,
            title: json["title"] as? String ?? "Untitled session",
            directory: json["directory"] as? String ?? "",
            updatedAt: Date(timeIntervalSince1970: millis / 1000)
        )
    }

    private static func parseMessage(_ json: [String: Any]) -> OpenCodeRemoteMessage? {
        guard let info = json["info"] as? [String: Any], let id = info["id"] as? String else { return nil }
        let role = info["role"] as? String ?? "assistant"
        let parts = (json["parts"] as? [[String: Any]] ?? []).compactMap(parsePart)
        return OpenCodeRemoteMessage(role: role, id: id, parts: parts)
    }

    private static func parsePart(_ json: [String: Any]) -> OpenCodeRemotePart? {
        guard let id = json["id"] as? String, let type = json["type"] as? String else { return nil }
        switch type {
        case "text":
            return OpenCodeRemotePart(id: id, kind: .text, text: json["text"] as? String, tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil)
        case "reasoning":
            return OpenCodeRemotePart(id: id, kind: .reasoning, text: json["text"] as? String, tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil)
        case "tool":
            let state = json["state"] as? [String: Any] ?? [:]
            let inputRaw = state["input"] as? [String: Any] ?? [:]
            let input = inputRaw.mapValues { String(describing: $0) }
            return OpenCodeRemotePart(
                id: id,
                kind: .tool,
                text: nil,
                tool: json["tool"] as? String,
                callID: json["callID"] as? String,
                status: state["status"] as? String,
                input: input,
                output: state["output"] as? String,
                error: state["error"] as? String
            )
        default:
            return OpenCodeRemotePart(id: id, kind: .other, text: nil, tool: nil, callID: nil, status: nil, input: [:], output: nil, error: nil)
        }
    }

    private static func parseEvent(_ data: Data) -> OpenCodeRemoteEvent? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (envelope["payload"] as? [String: Any]) ?? envelope
        guard let type = payload["type"] as? String else { return nil }
        let properties = payload["properties"] as? [String: Any] ?? [:]

        switch type {
        case "server.connected":
            return .connected
        case "message.part.updated":
            guard let partJSON = properties["part"] as? [String: Any], let part = parsePart(partJSON) else { return nil }
            return .part(part)
        case "permission.updated", "permission.asked":
            let p = (properties["permission"] as? [String: Any]) ?? properties
            guard let id = p["id"] as? String,
                  let sessionID = p["sessionID"] as? String else { return nil }
            let metadata = (p["metadata"] as? [String: Any] ?? [:]).mapValues { String(describing: $0) }
            return .permission(OpenCodeRemotePermission(
                id: id,
                sessionID: sessionID,
                title: p["title"] as? String ?? "Permission required",
                type: p["type"] as? String ?? "tool",
                metadata: metadata
            ))
        case "session.idle":
            guard let sessionID = properties["sessionID"] as? String else { return nil }
            return .sessionIdle(sessionID)
        case "session.error":
            let error = properties["error"] as? [String: Any]
            let data = error?["data"] as? [String: Any]
            return .sessionError(data?["message"] as? String ?? "OpenCode session error")
        default:
            return .other(type)
        }
    }

    // MARK: - Extended API (v1.18+)

    public struct RemoteFileNode: Sendable {
        public let name: String
        public let path: String
        public let absolutePath: String?
        public let isDirectory: Bool
        public let type: String?
        public let ignored: Bool?

        public init(name: String, path: String, absolutePath: String? = nil, isDirectory: Bool = false, type: String? = nil, ignored: Bool? = nil) {
            self.name = name
            self.path = path
            self.absolutePath = absolutePath
            self.isDirectory = isDirectory
            self.type = type
            self.ignored = ignored
        }
    }

    public struct RemoteFileContent: Sendable {
        public let path: String
        public let type: String
        public let content: String
        public let mimeType: String?
        public let encoding: String?
    }

    public struct RemoteFileStatus: Sendable {
        public let path: String
        public let status: String
        public let added: Bool?
        public let removed: Bool?
    }

    public struct SessionDiff: Sendable {
        public let file: String
        public let additions: Int
        public let deletions: Int
        public let before: String?
        public let after: String?
    }

    public struct ShellResult: Sendable {
        public let sessionID: String
        public let messageID: String
        public let parts: [OpenCodeRemotePart]
    }

    public struct ProviderInfo: Sendable {
        public let id: String
        public let name: String
        public let models: [String: [String: Any]]?
    }

    public struct ProviderListResult: Sendable {
        public let all: [ProviderInfo]
        public let connected: [String]
        public let default: String?
    }

    public struct ConfigInfo: Sendable {
        public let agents: [String: [String: Any]]?
        public let provider: [String: Any]?
    }

    public struct CommandInfo: Sendable {
        public let name: String
        public let description: String?
    }

    public func renameSession(sessionID: String, title: String) async throws {
        var body: [String: Any] = ["title": title]
        _ = try await request(path: "/session/\(sessionID)", method: "PATCH", jsonBody: body)
    }

    public func deleteSession(sessionID: String) async throws {
        _ = try await request(path: "/session/\(sessionID)", method: "DELETE", jsonBody: nil)
    }

    public func sessionDiff(sessionID: String) async throws -> [SessionDiff] {
        let data = try await request(path: "/session/\(sessionID)/diff")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OpenCodeRemoteError.invalidResponse
        }
        return array.compactMap { json in
            guard let file = json["file"] as? String else { return nil }
            let additions = json["additions"] as? Int ?? 0
            let deletions = json["deletions"] as? Int ?? 0
            let before = json["before"] as? String
            let after = json["after"] as? String
            return SessionDiff(file: file, additions: additions, deletions: deletions, before: before, after: after)
        }
    }

    public func listFiles(path: String = "") async throws -> [RemoteFileNode] {
        let query = path.isEmpty ? "" : "?path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        let data = try await request(path: "/file\(query)")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OpenCodeRemoteError.invalidResponse
        }
        return array.compactMap { json in
            guard let name = json["name"] as? String,
                  let path = json["path"] as? String else { return nil }
            let absolute = json["absolute"] as? String
            let isDir = (json["type"] as? String == "directory") || (json["type"] as? String == "folder")
            let ignored = json["ignored"] as? Bool
            return RemoteFileNode(name: name, path: path, absolutePath: absolute, isDirectory: isDir, type: json["type"] as? String, ignored: ignored)
        }
    }

    public func fileContent(path: String) async throws -> RemoteFileContent {
        let query = "?path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        let data = try await request(path: "/file/content\(query)")
        let json = try jsonObject(data)
        return RemoteFileContent(
            path: json["path"] as? String ?? path,
            type: json["type"] as? String ?? "text",
            content: json["content"] as? String ?? "",
            mimeType: json["mimeType"] as? String,
            encoding: json["encoding"] as? String
        )
    }

    public func fileStatus() async throws -> [RemoteFileStatus] {
        let data = try await request(path: "/file/status")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OpenCodeRemoteError.invalidResponse
        }
        return array.compactMap { json in
            guard let path = json["path"] as? String,
                  let status = json["status"] as? String else { return nil }
            return RemoteFileStatus(path: path, status: status, added: json["added"] as? Bool, removed: json["removed"] as? Bool)
        }
    }

    public func findFiles(query: String) async throws -> [String] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let data = try await request(path: "/find/file?query=\(q)")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw OpenCodeRemoteError.invalidResponse
        }
        return array
    }

    public func runShell(sessionID: String, command: String, agent: String? = nil, workdir: String? = nil) async throws -> ShellResult {
        var body: [String: Any] = ["command": command]
        if let agent { body["agent"] = agent }
        if let workdir { body["workdir"] = workdir }
        let data = try await request(path: "/session/\(sessionID)/shell", method: "POST", jsonBody: body)
        let json = try jsonObject(data)
        guard let info = json["info"] as? [String: Any],
              let messageID = info["id"] as? String,
              let partsJSON = json["parts"] as? [[String: Any]] else {
            throw OpenCodeRemoteError.invalidResponse
        }
        let parts = partsJSON.compactMap(Self.parsePart)
        return ShellResult(sessionID: sessionID, messageID: messageID, parts: parts)
    }

    public func providers() async throws -> ProviderListResult {
        let data = try await request(path: "/provider")
        let json = try jsonObject(data)
        let all = (json["all"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let id = dict["id"] as? String else { return nil }
            return ProviderInfo(id: id, name: dict["name"] as? String ?? id, models: dict["models"] as? [String: [String: Any]])
        }
        let connected = json["connected"] as? [String] ?? []
        let defaultProv = json["default"] as? String
        return ProviderListResult(all: all, connected: connected, default: defaultProv)
    }

    public func config() async throws -> ConfigInfo {
        let data = try await request(path: "/config")
        let json = try jsonObject(data)
        return ConfigInfo(
            agents: json["agent"] as? [String: [String: Any]],
            provider: json["provider"] as? [String: Any]
        )
    }

    public func commands() async throws -> [CommandInfo] {
        let data = try await request(path: "/command")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OpenCodeRemoteError.invalidResponse
        }
        return array.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            return CommandInfo(name: name, description: dict["description"] as? String)
        }
    }

    public func getPath() async throws -> String {
        let data = try await request(path: "/path")
        let json = try jsonObject(data)
        return json["path"] as? String ?? ""
    }

    public func sendPromptAsyncWithModel(sessionID: String, text: String, agent: String? = nil, modelProvider: String? = nil, modelID: String? = nil) async throws {
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        var body: [String: Any] = ["parts": parts]
        if let agent { body["agent"] = agent }
        if let modelProvider, let modelID {
            body["model"] = ["providerID": modelProvider, "modelID": modelID]
        }
        _ = try await request(path: "/session/\(sessionID)/prompt_async", method: "POST", jsonBody: body)
    }
}
