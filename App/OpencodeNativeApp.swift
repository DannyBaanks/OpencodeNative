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

// MARK: - Preview

#Preview {
    RootView()
        .environmentObject(SessionAdapter.preview())
        .environmentObject(SessionAdapter.preview().sessionState)
        .preferredColorScheme(.dark)
}