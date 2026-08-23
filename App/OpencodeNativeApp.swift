import SwiftUI
import OpencodeNativeCore

@main
public struct OpencodeNativeApp: App {
    @StateObject private var sessionAdapter = SessionAdapter()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sessionAdapter)
                .environmentObject(sessionAdapter.sessionState)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject private var adapter: SessionAdapter
    @EnvironmentObject private var sessionState: ActiveSessionState

    var body: some View {
        Group {
            if adapter.backendMode == .unconfigured {
                ConnectionView()
            } else {
                NavigationStack {
                    if sessionState.currentProject == nil {
                        ProjectListView()
                    } else if sessionState.currentSession == nil {
                        SessionListView(project: sessionState.currentProject!)
                    } else {
                        ActiveSessionView()
                    }
                }
            }
        }
        .onOpenURL { url in
            guard url.scheme == "opencodenative" else { return }
            adapter.connectRemote(url.absoluteString)
        }
    }
}
