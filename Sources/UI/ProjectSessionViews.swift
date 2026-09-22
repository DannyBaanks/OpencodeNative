import SwiftUI

public struct ProjectRow: View {
    let project: Project
    let isSelected: Bool
    let onTap: () -> Void
    
    public init(project: Project, isSelected: Bool = false, onTap: @escaping () -> Void) {
        self.project = project
        self.isSelected = isSelected
        self.onTap = onTap
    }
    
    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.base) {
                ZStack {
                    RoundedRectangle(cornerRadius: OCRadius.r8)
                        .fill(project.avatarColor?.opacity(0.3) ?? OCColor.bgLayer1)
                        .frame(width: 32, height: 32)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(project.avatarColor ?? OCColor.iconPrimary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(OCTypography.rowPrimary)
                        .foregroundColor(OCColor.textPrimary)
                        .lineLimit(1)
                    
                    Text(project.path.replacingOccurrences(of: "~/", with: "~/"))
                        .font(OCTypography.rowSecondary)
                        .foregroundColor(OCColor.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                HStack(spacing: OCSpacing.sm) {
                    if project.sessionCount > 0 {
                        Text("\(project.sessionCount)")
                            .font(OCTypography.metaMono)
                            .foregroundColor(OCColor.textFaint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(OCColor.bgLayer1)
                            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r4))
                    }
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(OCColor.iconMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, OCSpacing.contentMargin)
            .padding(.vertical, OCSpacing.lg)
            .background(
                isSelected ? OCColor.bgLayer1.opacity(0.5) : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(OCColor.borderMuted),
            alignment: .bottom
        )
    }
}

public struct ProjectListView: View {
    public init() {}
    
    public var body: some View {
        NavigationStack {
            ProjectListContent()
        }
    }
}

// Contenido de la lista de proyectos sin NavigationStack propio: lo usan el
// flujo iPhone (ProjectListView) y el sidebar del split en iPad (RootView).
public struct ProjectListContent: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @State private var selectedProject: Project?
    @State private var showSettings = false
    
    public init() {}
    
    public var body: some View {
        List {
            if store.projects.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(store.projects, content: projectRow)
                } header: {
                    Text("PROJECTS")
                        .font(OCTypography.sectionLabel)
                        .foregroundColor(OCColor.textFaint)
                        .padding(.horizontal, OCSpacing.contentMargin)
                        .padding(.top, OCSpacing.xl)
                        .padding(.bottom, OCSpacing.xs)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(OCColor.bgDeep)
        .navigationTitle("OpenCode")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17))
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(OCColor.bgDeep, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(store)
        }
    }

    // Extraido de la List: la expresion inline superaba el presupuesto de
    // type-check del compilador ("unable to type-check in reasonable time").
    @ViewBuilder
    private func projectRow(project: Project) -> some View {
        ProjectRow(
            project: project,
            isSelected: selectedProject?.id == project.id,
            onTap: { selectProject(project) }
        )
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // La seleccion vive en el onTap (no en onChange) para que re-tocar el
    // mismo proyecto en el sidebar del split tambien restaure el detalle.
    private func selectProject(_ project: Project) {
        selectedProject = project
        if let session = sessionState.currentSession, session.projectId != project.id {
            sessionState.currentSession = nil
        }
        sessionState.currentProject = project
        Task { await store.selectProject(project) }
    }

    private var emptyState: some View {
        VStack(spacing: OCSpacing.xl) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(OCColor.iconMuted)
            
            VStack(spacing: OCSpacing.xs) {
                Text("No Projects")
                    .font(OCTypography.bodyStrong)
                    .foregroundColor(OCColor.textPrimary)
                
                Text(store.backendMode == .remote
                     ? "Connect to an OpenCode server to see projects"
                     : "Start the native runtime to create a workspace")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textFaint)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(OCSpacing.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

public struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let onTap: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    
    public init(session: Session, isSelected: Bool = false, onTap: @escaping () -> Void, onRename: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.session = session
        self.isSelected = isSelected
        self.onTap = onTap
        self.onRename = onRename
        self.onDelete = onDelete
    }
    
    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.base) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: OCSpacing.xs) {
                        Text(session.title)
                            .font(OCTypography.rowPrimary)
                            .foregroundColor(OCColor.textPrimary)
                            .lineLimit(1)
                        
                        Circle()
                            .fill(session.agentMode.color)
                            .frame(width: 6, height: 6)
                        
                        if session.isRunning {
                            Circle()
                                .fill(session.agentMode.color)
                                .frame(width: 6, height: 6)
                                .modifier(PulsingDot())
                        }
                    }
                    
                    if let summary = session.lastEventSummary {
                        Text(summary)
                            .font(.system(size: 12.5, weight: .regular, design: .default))
                            .foregroundColor(OCColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.timestamp, style: .relative)
                        .font(OCTypography.metaMono)
                        .foregroundColor(OCColor.textFaint)
                    
                    if session.isDirty {
                        Circle()
                            .fill(OCColor.warning)
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(.horizontal, OCSpacing.contentMargin)
            .padding(.vertical, OCSpacing.lg)
            .frame(minHeight: 64)
            .background(
                isSelected ? OCColor.bgLayer1.opacity(0.5) : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", action: onRename)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(OCColor.borderMuted),
            alignment: .bottom
        )
    }
}

public struct SessionListView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    let project: Project
    @State private var selectedSession: Session?
    @State private var showNewSessionSheet = false
    @State private var sessionToRename: Session?
    @State private var renameTitle = ""
    @State private var showDeleteConfirm = false
    @State private var sessionToDelete: Session?
    @State private var searchText = ""
    
    public init(project: Project) {
        self.project = project
    }
    
    private var filteredSessions: [Session] {
        guard !searchText.isEmpty else { return store.sessions }
        return store.sessions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            ($0.lastEventSummary?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    
    public var body: some View {
        List {
            Section {
                ForEach(filteredSessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: selectedSession?.id == session.id,
                        onTap: {
                            // Seleccion directa (no onChange): re-tocar la misma
                            // sesion tras volver atras tambien debe re-entrar.
                            selectedSession = session
                            sessionState.currentSession = session
                            Task { await store.selectSession(session) }
                        },
                        onRename: { sessionToRename = session; renameTitle = session.title },
                        onDelete: { sessionToDelete = session; showDeleteConfirm = true }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            sessionToDelete = session
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("SESSIONS")
                    .font(OCTypography.sectionLabel)
                    .foregroundColor(OCColor.textFaint)
                    .padding(.horizontal, OCSpacing.contentMargin)
                    .padding(.top, OCSpacing.xl)
                    .padding(.bottom, OCSpacing.xs)
                    .textCase(nil)
            }
            
            if store.sessions.isEmpty {
                emptyState
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(OCColor.bgDeep)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                // RootView navega por estado, no por push: volver a la lista de
                // proyectos significa soltar currentProject.
                Button {
                    selectedSession = nil
                    sessionState.currentProject = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showNewSessionSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(OCColor.bgDeep, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search sessions"
        )
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionSheet(project: project) { title in
                Task {
                    _ = await store.createNewSession(in: project, title: title)
                }
            }
        }
        .sheet(item: $sessionToRename) { session in
            RenameSessionSheet(session: session, initialTitle: session.title) { newTitle in
                Task { await store.renameSession(session, title: newTitle) }
            }
        }
        .alert("Delete Session", isPresented: $showDeleteConfirm, presenting: sessionToDelete) { session in
            Button("Delete", role: .destructive) {
                Task { await store.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) { sessionToDelete = nil }
        } message: { session in
            Text("Delete \"\(session.title)\"? This action cannot be undone.")
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: OCSpacing.xl) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(OCColor.iconMuted)
            
            VStack(spacing: OCSpacing.xs) {
                Text("No Sessions")
                    .font(OCTypography.bodyStrong)
                    .foregroundColor(OCColor.textPrimary)
                
                Text("Create a session to start working")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textFaint)
                    .multilineTextAlignment(.center)
            }
            
            Button("New Session") { showNewSessionSheet = true }
                .font(OCTypography.control)
                .padding(.horizontal, OCSpacing.xl)
                .padding(.vertical, OCSpacing.base)
                .background(OCColor.agentBuild)
                .foregroundColor(OCColor.bgDeep)
                .clipShape(RoundedRectangle(cornerRadius: OCRadius.r24))
        }
        .padding(OCSpacing.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

private struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let onCreate: (String) -> Void
    @State private var title = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Session Details") {
                    TextField("Title (optional)", text: $title)
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(title)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct RenameSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: Session
    let initialTitle: String
    let onRename: (String) -> Void
    @State private var title = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Rename Session") {
                    TextField("Title", text: $title)
                }
            }
            .navigationTitle("Rename Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onRename(title)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == initialTitle)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { title = initialTitle }
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkbenchStore
    @State private var hasStoredPairing = false
    @State private var showRemoteUnavailableNote = false
    
    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    if store.backendMode == .remote {
                        HStack {
                            Text("Status")
                            Spacer()
                            Text(store.connectionStatus)
                                .font(OCTypography.metaMono)
                                .foregroundColor(OCColor.textFaint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack {
                            Text("Health")
                            Spacer()
                            Text(store.connectionHealth.rawValue.capitalized)
                                .font(OCTypography.metaMono)
                                .foregroundColor(healthColor)
                        }
                        Button("Forget Connection") {
                            Task {
                                await store.forgetPairing()
                                await store.disconnect()
                            }
                        }
                        .foregroundColor(OCColor.danger)
                    } else {
                        Text("Not connected")
                            .foregroundColor(OCColor.textFaint)
                    }
                }
                
                Section("Runtime") {
                    Picker("Mode", selection: modeBinding) {
                        Text("Remote (OpenCode Server)").tag(BackendMode.remote.rawValue)
                        Text("Native (Swift Sandbox)").tag(BackendMode.native.rawValue)
                    }
                    
                    if store.backendMode == .native {
                        NavigationLink("API Keys") {
                            APIKeysView()
                        }
                    }
                    
                    if showRemoteUnavailableNote {
                        Text("No stored pairing — link a desktop first.")
                            .font(OCTypography.meta)
                            .foregroundColor(OCColor.warning)
                    }
                }
                
                Section("Attribution") {
                    HStack {
                        Text("OpenCode")
                        Spacer()
                        Text("MIT License")
                            .foregroundColor(OCColor.textFaint)
                    }
                    HStack {
                        Text("OpencodeNative")
                        Spacer()
                        Text("Not affiliated with OpenCode")
                            .foregroundColor(OCColor.textFaint)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                Task { hasStoredPairing = await store.hasStoredPairing() }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    // El picker conmuta de verdad: `native` arranca el runtime Swift; `remote`
    // reconecta el pairing guardado (o avisa si no existe ninguno).
    private var modeBinding: Binding<String> {
        Binding(
            get: { store.backendMode.rawValue },
            set: { newValue in
                if newValue == BackendMode.native.rawValue {
                    Task { await store.useNativeRuntime() }
                } else if hasStoredPairing {
                    Task { await store.reconnectStoredPairing() }
                } else {
                    showRemoteUnavailableNote = true
                }
            }
        )
    }
    
    private var healthColor: Color {
        switch store.connectionHealth {
        case .connected: return OCColor.success
        case .connecting: return OCColor.warning
        case .disconnected: return OCColor.danger
        }
    }
}

struct APIKeysView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkbenchStore
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var googleKey = ""
    
    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API Key", text: $openAIKey)
                    .autocorrectionDisabled()
            }
            Section("Anthropic") {
                SecureField("API Key", text: $anthropicKey)
                    .autocorrectionDisabled()
            }
            Section("Google") {
                SecureField("API Key", text: $googleKey)
                    .autocorrectionDisabled()
            }
        }
        .navigationTitle("API Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await store.saveAPIKeys(openAI: openAIKey, anthropic: anthropicKey, google: googleKey)
                        openAIKey = ""
                        anthropicKey = ""
                        googleKey = ""
                        dismiss()
                    }
                }
                .disabled(openAIKey.isEmpty && anthropicKey.isEmpty && googleKey.isEmpty)
            }
        }
    }
}

// Indicador "running" de sesion: punto con pulso (antes era un segundo punto
// estatico identico al de agentMode, indistinguible a la vista).
struct PulsingDot: ViewModifier {
    @State private var pulsing = false
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1.4 : 1.0)
            .opacity(pulsing ? 0.55 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}