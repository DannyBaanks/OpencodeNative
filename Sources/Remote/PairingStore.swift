import Foundation
import Security

public actor PairingStore {
    private let keychain = KeychainHelper.shared
    private let pairingKey = "opencodenative_pairing"

    public init() {}

    public struct StoredPairing: Codable, Sendable {
        public let host: String
        public let port: Int
        public let username: String
        public let password: String
        public let directory: String
        public let createdAt: Date

        public init(host: String, port: Int, username: String, password: String, directory: String, createdAt: Date = Date()) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.directory = directory
            self.createdAt = createdAt
        }
    }

    public func save(_ pairing: OpenCodePairing) async throws {
        let stored = StoredPairing(
            host: pairing.host,
            port: pairing.port,
            username: pairing.username,
            password: pairing.password,
            directory: pairing.directory
        )
        let data = try JSONEncoder().encode(stored)
        try await keychain.save(key: pairingKey, value: String(data: data, encoding: .utf8)!)
    }

    public func load() async throws -> StoredPairing? {
        guard let json = try await keychain.load(key: pairingKey),
              let data = json.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(StoredPairing.self, from: data)
    }

    public func clear() async throws {
        try await keychain.delete(key: pairingKey)
    }

    public func hasStoredPairing() async -> Bool {
        do {
            return try await load() != nil
        } catch {
            return false
        }
    }
}