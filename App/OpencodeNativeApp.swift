import SwiftUI
import UIKit
import OpencodeNativeCore

@main
public struct OpencodeNativeApp: App {
    @UIApplicationDelegateAdaptor(FullScreenAppDelegate.self) private var appDelegate
    @StateObject private var store = WorkbenchStore()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.sessionState)
                .preferredColorScheme(.dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OCColor.bgDeep.ignoresSafeArea())
                .onAppear { FullScreenAppDelegate.expandWindows() }
        }
    }
}

/// iOS letterboxes the process when it does not see a real launch screen.
/// Sideload hosts can also hand the scene a window smaller than the display.
/// Stretch every window to the screen the system actually gave us.
final class FullScreenAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Self.expandWindows()
        }
        return true
    }

    static func expandWindows() {
        let fill = UIColor(red: 8.0 / 255.0, green: 8.0 / 255.0, blue: 8.0 / 255.0, alpha: 1)
        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            let bounds = windowScene.screen.bounds
            windowScene.sizeRestrictions?.minimumSize = bounds.size
            windowScene.sizeRestrictions?.maximumSize = bounds.size
            for window in windowScene.windows {
                if window.frame != bounds {
                    window.frame = bounds
                }
                window.backgroundColor = fill
            }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OCColor.bgDeep.ignoresSafeArea())
        .onOpenURL { url in
            guard url.scheme == "opencodenative" else { return }
            Task { await store.connectRemote(url.absoluteString) }
        }
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
