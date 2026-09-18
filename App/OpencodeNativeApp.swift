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
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if store.backendMode == .unconfigured {
                ConnectionView()
            } else if sizeClass == .regular {
                // iPad / ancho regular: sidebar de proyectos + detalle.
                splitLayout
            } else {
                stackLayout
            }
        }
        .onOpenURL { url in
            guard url.scheme == "opencodenative" else { return }
            Task { await store.connectRemote(url.absoluteString) }
        }
    }

    // Flujo iPhone: navegacion por estado dentro de un NavigationStack.
    private var stackLayout: some View {
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

    // Ancho regular: el sidebar persiste y el detalle cambia por estado,
    // reutilizando exactamente las mismas vistas del flujo compacto.
    private var splitLayout: some View {
        NavigationSplitView {
            ProjectListContent()
        } detail: {
            if let project = sessionState.currentProject {
                if sessionState.currentSession != nil {
                    ActiveSessionView()
                } else {
                    SessionListView(project: project)
                }
            } else {
                SplitPlaceholderView()
            }
        }
    }
}

// Placeholder del detalle del split cuando aun no hay proyecto elegido.
struct SplitPlaceholderView: View {
    var body: some View {
        VStack(spacing: OCSpacing.base) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(OCColor.iconMuted)
            Text("Select a project")
                .font(OCTypography.bodyStrong)
                .foregroundColor(OCColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OCColor.bgDeep.ignoresSafeArea())
    }
}
