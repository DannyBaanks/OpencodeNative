import Foundation

public actor CodexPairingStore {
    private let keychain = KeychainHelper.shared
    private let defaults: UserDefaults
    private let metadataKey = "iyscodemovil_codex_pairing_metadata"
    private let tokenKey = "iyscodemovil_codex_pairing_token"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private struct Metadata: Codable, Sendable {
        let host: String
        let port: Int
        let directory: String
        let codexVersion: String
        let profile: CodexCapabilityProfile
    }

    public func save(_ pairing: CodexPairing) async throws {
        let metadata = Metadata(
            host: pairing.host,
            port: pairing.port,
            directory: pairing.directory,
            codexVersion: pairing.codexVersion,
            profile: pairing.profile
        )
        let encoded = try JSONEncoder().encode(metadata)
        try await keychain.save(key: tokenKey, value: pairing.token)
        defaults.set(encoded, forKey: metadataKey)
    }

    public func load() async throws -> CodexPairing? {
        guard let encoded = defaults.data(forKey: metadataKey) else { return nil }
        let metadata = try JSONDecoder().decode(Metadata.self, from: encoded)
        guard let token = try await keychain.load(key: tokenKey) else { return nil }
        return try CodexPairing(
            host: metadata.host,
            port: metadata.port,
            token: token,
            directory: metadata.directory,
            codexVersion: metadata.codexVersion,
            profile: metadata.profile
        )
    }

    public func clear() async throws {
        if try await keychain.load(key: tokenKey) != nil {
            try await keychain.delete(key: tokenKey)
        }
        defaults.removeObject(forKey: metadataKey)
    }

    public func hasStoredPairing() async -> Bool {
        (try? await load()) != nil
    }
}
