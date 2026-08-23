import SwiftUI
import OpencodeNativeCore

@main
public struct OpencodeNativeApp: App {
    @StateObject private var store = WorkbenchStore()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.sessionState)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState

    var body: some View {
        Group {
            if store.backendMode == .unconfigured {
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
            Task { await store.connectRemote(url.absoluteString) }
        }
    }
}
