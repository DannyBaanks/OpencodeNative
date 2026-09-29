import Foundation

enum GUSDualModelExperimentSettings {
    static let enabledKey = "gus.dualSmolExperimentalEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}
