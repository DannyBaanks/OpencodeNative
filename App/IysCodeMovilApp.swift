import SwiftUI
import UIKit
import IysCodeMovilCore

@main
public struct IysCodeMovilApp: App {
    @StateObject private var store = WorkbenchStore()
    @StateObject private var hostStore = MobileHostStore()

    public init() {
        IysThemePreferences.applyPendingOnLaunch()
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(hostStore)
                .environmentObject(store.sessionState)
                .preferredColorScheme(.dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OCColor.bgDeep.ignoresSafeArea())
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var hostStore: MobileHostStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var enteredBackground = false

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OCColor.bgDeep.ignoresSafeArea())
        .task {
            await hostStore.restore()
            await hostStore.setAppActive(scenePhase == .active)
            consumePendingAppIntent()
        }
        .onOpenURL { url in
            guard url.scheme == "iyscodemovil" else { return }
            if url.host == "native", url.path == "/sandbox" {
                Task { await store.useNativeRuntime() }
            } else {
                Task { await store.connectRemote(url.absoluteString) }
            }
        }
        .onChange(of: scenePhase) { phase in
            Task { await hostStore.setAppActive(phase == .active) }
            if phase == .active { consumePendingAppIntent() }
            if phase == .background {
                enteredBackground = true
            } else if phase == .active, enteredBackground {
                enteredBackground = false
                Task { await store.resumeRemoteSessionAfterBackground() }
            }
        }
    }

    private func consumePendingAppIntent() {
        guard UserDefaults.standard.bool(forKey: "native.openSandboxOnLaunch") else { return }
        UserDefaults.standard.removeObject(forKey: "native.openSandboxOnLaunch")
        Task { await store.useNativeRuntime() }
    }

    // Flujo iPhone: navegacion por estado dentro de un NavigationStack.
    private var stackLayout: some View {
        NavigationStack {
            if sessionState.currentProject == nil {
                ProjectListContent()
            } else if sessionState.currentSession == nil {
                SessionListView(project: sessionState.currentProject!)
            } else {
                ActiveSessionView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
