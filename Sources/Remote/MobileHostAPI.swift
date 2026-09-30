import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MobileHostCredential: Codable, Sendable, Equatable {
    public let baseURL: String
    public let keyID: String
    public let expiresAt: String
    public let scopes: [String]

    public init(baseURL: String, keyID: String, expiresAt: String, scopes: [String]) {
        self.baseURL = baseURL
        self.keyID = keyID
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    public var expirationDate: Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: expiresAt) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: expiresAt)
    }
}

public enum MobileHostAPIError: Error, LocalizedError, Sendable {
    case invalidBaseURL
    case invalidPairingCode
    case invalidResponse
    case unauthorized
    case expiredCredential
    case rejected(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Use an HTTPS host URL. HTTP is allowed only for loopback development."
        case .invalidPairingCode:
            return "The pairing code must contain six digits."
        case .invalidResponse:
            return "The host returned an invalid response."
        case .unauthorized:
            return "The host rejected this credential. Pair this iPhone again."
        case .expiredCredential:
            return "This pairing credential has expired. Pair this iPhone again."
        case .rejected(let status, let reason):
            if let reason, !reason.isEmpty { return "The host rejected the request (HTTP \(status)): \(reason)" }
            return "The host rejected the request (HTTP \(status))."
        }
    }
}

private final class RejectHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Pairing credentials must never follow a server redirect to a different
        // origin or transport. Configure the host URL explicitly instead.
        completionHandler(nil)
    }
}

/// Client for the implemented portion of the ISyCode Mobile Host v1 contract.
/// It intentionally has no session, runtime-selection, or approval methods.
public struct MobileHostAPI: Sendable {
    private struct PairExchangeRequest: Encodable {
        let code: String
        let deviceName: String

        enum CodingKeys: String, CodingKey {
            case code
            case deviceName = "device_name"
        }
    }

    private struct PairExchangeResponse: Decodable {
        let apiKey: String
        let keyID: String
        let expiresAt: String
        let scopes: [String]

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case keyID = "key_id"
            case expiresAt = "expires_at"
            case scopes
        }
    }

    private struct HeartbeatRequest: Encodable {
        let clientID: String
        let deviceName: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case deviceName = "device_name"
        }
    }

    public init() {}

    public func normalizedBaseURL(_ rawValue: String) throws -> URL {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw MobileHostAPIError.invalidBaseURL
        }
        let loopback = host == "localhost" || host == "::1" || host == "[::1]"
            || host == "127.0.0.1" || host.hasPrefix("127.")
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw MobileHostAPIError.invalidBaseURL
        }
        // Keep an optional deployment mount point (for example `/isycode`).
        // Restrict it to simple path segments so URL normalization cannot
        // escape the configured prefix or reinterpret encoded separators.
        let pathSegments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathSegments.allSatisfy({ segment in
            !segment.isEmpty && segment != "." && segment != ".."
                && segment.unicodeScalars.allSatisfy {
                    CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~.")
                        .contains($0)
                }
        }) else {
            throw MobileHostAPIError.invalidBaseURL
        }
        components.path = pathSegments.isEmpty ? "" : "/" + pathSegments.joined(separator: "/")
        guard let url = components.url else { throw MobileHostAPIError.invalidBaseURL }
        return url
    }

    public func checkHealth(baseURL: String) async throws {
        let base = try normalizedBaseURL(baseURL)
        let (_, status) = try await send(path: "v1/health", method: "GET", baseURL: base)
        guard status == 200 else { throw MobileHostAPIError.rejected(status, nil) }
    }

    public func exchangePairingCode(baseURL: String, code: String, deviceName: String) async throws -> (MobileHostCredential, String) {
        let normalizedCode = String(code.filter { $0 >= "0" && $0 <= "9" })
        guard normalizedCode.utf8.count == 6,
              normalizedCode.utf8.allSatisfy({ (48...57).contains($0) }),
              normalizedCode == code else {
            throw MobileHostAPIError.invalidPairingCode
        }
        let base = try normalizedBaseURL(baseURL)
        let body = try Self.makeEncoder().encode(PairExchangeRequest(code: normalizedCode, deviceName: deviceName))
        let (data, status) = try await send(path: "v1/pair/exchange", method: "POST", baseURL: base, body: body)
        guard status == 201 else { throw Self.rejection(data: data, status: status) }
        let response = try Self.makeDecoder().decode(PairExchangeResponse.self, from: data)
        guard !response.apiKey.isEmpty, !response.keyID.isEmpty,
              !response.expiresAt.isEmpty, let expiration = Self.parseDate(response.expiresAt),
              expiration > Date() else {
            throw MobileHostAPIError.invalidResponse
        }
        let credential = MobileHostCredential(
            baseURL: base.absoluteString,
            keyID: response.keyID,
            expiresAt: response.expiresAt,
            scopes: response.scopes
        )
        return (credential, response.apiKey)
    }

    public func sendHeartbeat(baseURL: String, apiKey: String, clientID: String, deviceName: String) async throws {
        let base = try normalizedBaseURL(baseURL)
        let body = try Self.makeEncoder().encode(HeartbeatRequest(clientID: clientID, deviceName: deviceName))
        let (data, status) = try await send(
            path: "v1/clients/heartbeat",
            method: "POST",
            baseURL: base,
            apiKey: apiKey,
            body: body
        )
        if status == 401 { throw MobileHostAPIError.unauthorized }
        if status == 410 { throw MobileHostAPIError.expiredCredential }
        guard (200..<300).contains(status) else { throw Self.rejection(data: data, status: status) }
    }

    private func send(path: String, method: String, baseURL: URL, apiKey: String? = nil, body: Data? = nil) async throws -> (Data, Int) {
        guard !path.hasPrefix("/"),
              let endpoint = URLComponents(string: path),
              endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              var baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MobileHostAPIError.invalidBaseURL
        }
        let basePath = baseComponents.path.split(separator: "/", omittingEmptySubsequences: true)
        let endpointPath = endpoint.path.split(separator: "/", omittingEmptySubsequences: true)
        baseComponents.path = "/" + (basePath + endpointPath).joined(separator: "/")
        guard let url = baseComponents.url else { throw MobileHostAPIError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession(configuration: .ephemeral, delegate: RejectHostRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MobileHostAPIError.invalidResponse }
        return (data, response.statusCode)
    }

    private static func makeEncoder() -> JSONEncoder {
        JSONEncoder()
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private static func rejection(data: Data, status: Int) -> MobileHostAPIError {
        let firstLine = String(data: data, encoding: .utf8)?
            .components(separatedBy: .newlines).first ?? ""
        let cleaned = String(firstLine.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        let reason = cleaned.isEmpty ? nil : String(cleaned.prefix(120))
        return .rejected(status, reason)
    }
}

public actor MobileHostCredentialStore {
    private let keychain = KeychainHelper.shared
    private let defaults: UserDefaults
    private let metadataKey = "iyscodemovil_mobile_host_v1_metadata"
    private let apiKeyKey = "iyscodemovil_mobile_host_v1_api_key"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ credential: MobileHostCredential, apiKey: String) async throws {
        try await keychain.save(key: apiKeyKey, value: apiKey)
        let data = try JSONEncoder().encode(credential)
        defaults.set(data, forKey: metadataKey)
    }

    public func load() async throws -> (MobileHostCredential, String)? {
        guard let data = defaults.data(forKey: metadataKey) else { return nil }
        let credential = try JSONDecoder().decode(MobileHostCredential.self, from: data)
        guard let apiKey = try await keychain.load(key: apiKeyKey) else {
            defaults.removeObject(forKey: metadataKey)
            return nil
        }
        return (credential, apiKey)
    }

    public func clear() async throws {
        try await keychain.delete(key: apiKeyKey)
        defaults.removeObject(forKey: metadataKey)
    }
}
