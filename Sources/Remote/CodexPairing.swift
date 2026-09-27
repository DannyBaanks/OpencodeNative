import Foundation

public struct CodexCapabilityProfile: Codable, Equatable, Sendable {
    public let profileVersion: Int
    public let initialize: Bool
    public let threadList: Bool
    public let threadStart: Bool
    public let threadResume: Bool
    public let threadRead: Bool
    public let turnStart: Bool
    public let turnInterrupt: Bool
    public let textStreaming: Bool
    public let commandApproval: Bool
    public let fileApproval: Bool
    public let schemaSHA256: String
    /// Optional so saved pairing links from earlier bridge versions still decode.
    public let modelList: Bool?

    public init(profileVersion: Int, initialize: Bool, threadList: Bool, threadStart: Bool, threadResume: Bool, threadRead: Bool, turnStart: Bool, turnInterrupt: Bool, textStreaming: Bool, commandApproval: Bool, fileApproval: Bool, schemaSHA256: String, modelList: Bool? = nil) {
        self.profileVersion = profileVersion
        self.initialize = initialize
        self.threadList = threadList
        self.threadStart = threadStart
        self.threadResume = threadResume
        self.threadRead = threadRead
        self.turnStart = turnStart
        self.turnInterrupt = turnInterrupt
        self.textStreaming = textStreaming
        self.commandApproval = commandApproval
        self.fileApproval = fileApproval
        self.schemaSHA256 = schemaSHA256
        self.modelList = modelList
    }

    public var supportsCoreConversation: Bool {
        profileVersion == 1 && initialize && threadList && threadStart && threadResume
            && threadRead && turnStart && turnInterrupt && textStreaming
            && schemaSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

public struct CodexPairing: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let token: String
    public let directory: String
    public let codexVersion: String
    public let profile: CodexCapabilityProfile

    public init(host: String, port: Int, token: String, directory: String, codexVersion: String, profile: CodexCapabilityProfile) throws {
        guard Self.isTailscaleIPv4(host), (1...65535).contains(port), token.count >= 32,
              !directory.isEmpty, !codexVersion.isEmpty, profile.supportsCoreConversation else {
            throw CodexPairingError.invalidPairing
        }
        self.host = host
        self.port = port
        self.token = token
        self.directory = directory
        self.codexVersion = codexVersion
        self.profile = profile
    }

    public static func parse(_ rawValue: String) throws -> CodexPairing {
        guard let url = URL(string: rawValue) else { throw CodexPairingError.invalidPairing }
        return try parse(url: url)
    }

    public static func parse(url: URL) throws -> CodexPairing {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "codex", components.host == "pair",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil else {
            throw CodexPairingError.invalidPairing
        }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, values.updateValue(value, forKey: item.name) == nil else {
                throw CodexPairingError.invalidPairing
            }
        }
        let allowed = Set(["host", "port", "directory", "token", "codexVersion", "profile"])
        guard Set(values.keys).isSubset(of: allowed) else { throw CodexPairingError.invalidPairing }
        guard let host = values["host"], let portText = values["port"], let port = Int(portText),
              let token = values["token"], let directory = values["directory"],
              let codexVersion = values["codexVersion"], let profileJSON = values["profile"],
              let profileData = profileJSON.data(using: .utf8),
              let profile = try? JSONDecoder().decode(CodexCapabilityProfile.self, from: profileData) else {
            throw CodexPairingError.invalidPairing
        }
        return try CodexPairing(host: host, port: port, token: token, directory: directory, codexVersion: codexVersion, profile: profile)
    }

    /// Pairing URLs exist only during onboarding/import; do not persist this string.
    public var rawValue: String {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "pair"
        let profileData = (try? JSONEncoder().encode(profile)) ?? Data()
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "directory", value: directory),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "codexVersion", value: codexVersion),
            URLQueryItem(name: "profile", value: String(data: profileData, encoding: .utf8) ?? "")
        ]
        return components.url?.absoluteString ?? ""
    }

    private static func isTailscaleIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}

public enum CodexPairingError: Error, LocalizedError, Sendable {
    case invalidPairing

    public var errorDescription: String? {
        "Invalid Codex pairing link or unsupported App Server profile."
    }
}
