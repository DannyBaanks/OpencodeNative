import AppIntents

@available(iOS 16.0, *)
struct OpenISyCodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Open iSyCode Móvil"
    static var description = IntentDescription("Open your iPhone development workspace.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

@available(iOS 16.0, *)
struct OpenSandboxIntent: AppIntent {
    static var title: LocalizedStringResource = "Open iSyCode Sandbox"
    static var description = IntentDescription("Open the local iPhone workspace in iSyCode Móvil.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        // iOS 16 App Intents can activate the app, while OpenURLIntent itself
        // is iOS 18+. Persist a one-shot typed action for the app to consume.
        UserDefaults.standard.set(true, forKey: "native.openSandboxOnLaunch")
        return .result()
    }
}

@available(iOS 16.0, *)
struct ISyCodeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenISyCodeIntent(),
            phrases: ["Open \(.applicationName)", "Open my workspace in \(.applicationName)"],
            shortTitle: "Open iSyCode",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: OpenSandboxIntent(),
            phrases: ["Open my iPhone sandbox in \(.applicationName)"],
            shortTitle: "Open Sandbox",
            systemImageName: "iphone"
        )
    }
}
