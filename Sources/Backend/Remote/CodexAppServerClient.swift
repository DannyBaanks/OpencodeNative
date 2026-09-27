import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodexJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([CodexJSONValue])
    case object([String: CodexJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([CodexJSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: CodexJSONValue].self) { self = .object(value) }
        else { throw CodexAppServerError.invalidMessage }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public enum CodexAppServerRequestID: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int64)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else { throw CodexAppServerError.invalidMessage }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        }
    }
}

public enum CodexAppServerEvent: Sendable {
    case notification(method: String, params: CodexJSONValue)
    case request(id: CodexAppServerRequestID, method: String, params: CodexJSONValue)
    case disconnected(String?)
}

public enum CodexAppServerError: Error, LocalizedError, Sendable {
    case invalidEndpoint
    case invalidPairing
    case notConnected
    case notInitialized
    case authenticationFailed
    case protocolMismatch(expected: String, received: String)
    case requestTimedOut(String)
    case requestFailed(Int, String)
    case invalidMessage

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Codex App Server endpoint is invalid."
        case .invalidPairing: return "Codex pairing profile is incomplete."
        case .notConnected: return "Codex App Server is disconnected."
        case .notInitialized: return "Codex App Server has not completed initialize."
        case .authenticationFailed: return "Codex App Server rejected the pairing token."
        case .protocolMismatch(let expected, let received): return "Codex protocol mismatch (expected \(expected), received \(received))."
        case .requestTimedOut(let method): return "Codex App Server request timed out: \(method)."
        case .requestFailed(let code, let message): return "Codex App Server request failed (\(code)): \(message)"
        case .invalidMessage: return "Codex App Server sent an invalid JSON-RPC message."
        }
    }
}

private struct CodexRPCInbound: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        let code: Int
        let message: String
    }

    let id: CodexAppServerRequestID?
    let method: String?
    let params: CodexJSONValue?
    let result: CodexJSONValue?
    let error: Failure?
}

private struct CodexRPCRequest: Encodable {
    let id: CodexAppServerRequestID
    let method: String
    let params: CodexJSONValue
}

private struct CodexRPCNotification: Encodable {
    let method: String
    let params: CodexJSONValue
}

private struct CodexRPCResponse: Encodable {
    let id: CodexAppServerRequestID
    let result: CodexJSONValue
}

public actor CodexAppServerClient {
    public let events: AsyncStream<CodexAppServerEvent>

    private let endpoint: URL
    private let token: String
    private let expectedVersion: String
    private let profile: CodexCapabilityProfile
    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?
    private var readTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<CodexAppServerEvent>.Continuation?
    private var pending: [CodexAppServerRequestID: CheckedContinuation<CodexJSONValue, Error>] = [:]
    private var timeouts: [CodexAppServerRequestID: Task<Void, Never>] = [:]
    private var nextID: Int64 = 1
    private var isInitialized = false

    public init(pairing: CodexPairing) throws {
        guard Self.profileIsUsable(pairing.profile), let endpoint = URL(string: "ws://\(pairing.host):\(pairing.port)") else {
            throw CodexAppServerError.invalidPairing
        }
        self.endpoint = endpoint
        self.token = pairing.token
        self.expectedVersion = pairing.codexVersion
        self.profile = pairing.profile
        self.urlSession = URLSession(configuration: .ephemeral)
        var continuation: AsyncStream<CodexAppServerEvent>.Continuation?
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    public func connect() async throws {
        guard Self.profileIsUsable(profile), endpoint.scheme == "ws", endpoint.host != nil else {
            throw CodexAppServerError.invalidPairing
        }
        guard socket == nil else { return }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = urlSession.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        readTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }

        do {
            let initialize = CodexJSONValue.object([
                "clientInfo": .object([
                    "name": .string("ISyCodeMovil"),
                    "version": .string("0.1.0")
                ]),
                "capabilities": .object(["experimentalApi": .bool(false)])
            ])
            let result = try await sendRequest(method: "initialize", params: initialize)
            guard case .object(let fields) = result,
                  case .string(let userAgent)? = fields["userAgent"] else {
                throw CodexAppServerError.invalidMessage
            }
            guard let expected = expectedVersion.split(separator: " ").last,
                  userAgent.contains(expected) else {
                throw CodexAppServerError.protocolMismatch(expected: expectedVersion, received: userAgent)
            }
            try await sendNotification(method: "initialized", params: .object([:]))
            isInitialized = true
        } catch {
            await disconnect(reason: "initialize failed")
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorBadServerResponse {
                throw CodexAppServerError.authenticationFailed
            }
            throw error
        }
    }

    public func request(method: String, params: CodexJSONValue = .object([:])) async throws -> CodexJSONValue {
        guard isInitialized else { throw CodexAppServerError.notInitialized }
        return try await sendRequest(method: method, params: params)
    }

    public func respond(id: CodexAppServerRequestID, result: CodexJSONValue) async throws {
        guard socket != nil else { throw CodexAppServerError.notConnected }
        try await send(CodexRPCResponse(id: id, result: result))
    }

    public func disconnect(reason: String? = nil) async {
        isInitialized = false
        readTask?.cancel()
        readTask = nil
        let socket = self.socket
        self.socket = nil
        socket?.cancel(with: .goingAway, reason: nil)
        failPending(CodexAppServerError.notConnected)
        eventContinuation?.yield(.disconnected(reason))
        eventContinuation?.finish()
    }

    private func sendRequest(method: String, params: CodexJSONValue) async throws -> CodexJSONValue {
        guard socket != nil else { throw CodexAppServerError.notConnected }
        let id = CodexAppServerRequestID.integer(nextID)
        nextID += 1
        let payload = try JSONEncoder.codex.encode(CodexRPCRequest(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.timeout(id: id, method: method)
            }
            Task { [weak self] in await self?.sendPending(payload, id: id) }
        }
    }

    private func sendPending(_ data: Data, id: CodexAppServerRequestID) async {
        do {
            guard let socket else { throw CodexAppServerError.notConnected }
            guard let message = String(data: data, encoding: .utf8) else {
                throw CodexAppServerError.invalidMessage
            }
            try await socket.send(.string(message))
        } catch {
            timeouts.removeValue(forKey: id)?.cancel()
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    private func sendNotification(method: String, params: CodexJSONValue) async throws {
        try await send(CodexRPCNotification(method: method, params: params))
    }

    private func send<T: Encodable>(_ value: T) async throws {
        guard let socket else { throw CodexAppServerError.notConnected }
        let data = try JSONEncoder.codex.encode(value)
        guard let message = String(data: data, encoding: .utf8) else {
            throw CodexAppServerError.invalidMessage
        }
        try await socket.send(.string(message))
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                guard let socket else { return }
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let received): data = received
                case .string(let received): data = Data(received.utf8)
                @unknown default: throw CodexAppServerError.invalidMessage
                }
                try route(try JSONDecoder().decode(CodexRPCInbound.self, from: data))
            }
        } catch is CancellationError {
            return
        } catch {
            failPending(error)
            let failedSocket = socket
            socket = nil
            isInitialized = false
            failedSocket?.cancel(with: .abnormalClosure, reason: nil)
            eventContinuation?.yield(.disconnected(error.localizedDescription))
            eventContinuation?.finish()
        }
    }

    private func route(_ frame: CodexRPCInbound) throws {
        if let method = frame.method {
            guard !method.isEmpty, frame.result == nil, frame.error == nil else {
                throw CodexAppServerError.invalidMessage
            }
            let params = frame.params ?? .object([:])
            if let id = frame.id {
                eventContinuation?.yield(.request(id: id, method: method, params: params))
            } else {
                eventContinuation?.yield(.notification(method: method, params: params))
            }
            return
        }
        guard frame.id != nil, frame.params == nil,
              (frame.result == nil) != (frame.error == nil) else {
            throw CodexAppServerError.invalidMessage
        }
        guard let id = frame.id, let continuation = pending.removeValue(forKey: id) else {
            throw CodexAppServerError.invalidMessage
        }
        timeouts.removeValue(forKey: id)?.cancel()
        if let error = frame.error {
            continuation.resume(throwing: CodexAppServerError.requestFailed(error.code, error.message))
        } else if let result = frame.result {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: CodexAppServerError.invalidMessage)
        }
    }

    private func timeout(id: CodexAppServerRequestID, method: String) {
        timeouts.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: CodexAppServerError.requestTimedOut(method))
    }

    private func failPending(_ error: Error) {
        let continuations = Array(pending.values)
        pending.removeAll()
        let tasks = Array(timeouts.values)
        timeouts.removeAll()
        for task in tasks { task.cancel() }
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private static func profileIsUsable(_ profile: CodexCapabilityProfile) -> Bool {
        profile.supportsCoreConversation
    }
}

private extension JSONEncoder {
    static var codex: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
