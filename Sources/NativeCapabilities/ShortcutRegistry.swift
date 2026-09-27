import Foundation

public struct ConfiguredShortcut: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ShortcutRegistry {
    private static let storageKey = "native.configuredShortcut"

    public static func loadConfiguredShortcut(from defaults: UserDefaults = .standard) -> ConfiguredShortcut? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(ConfiguredShortcut.self, from: data)
    }

    public static func save(_ shortcut: ConfiguredShortcut, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: storageKey)
    }

    public static func remove(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

public enum ShortcutURLBuilder {
    /// Only a locally configured reference can be passed here; this is not shortcut enumeration.
    public static func runURL(shortcut: ConfiguredShortcut, text: String? = nil) -> URL? {
        guard !shortcut.name.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var items = [URLQueryItem(name: "name", value: shortcut.name)]
        if let text, !text.isEmpty { items.append(URLQueryItem(name: "text", value: text)) }
        components.queryItems = items
        return components.url
    }
}
