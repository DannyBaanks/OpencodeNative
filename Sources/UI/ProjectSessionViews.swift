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
    @EnvironmentObject private var store: WorkbenchStore
    @EnvironmentObject private var sessionState: ActiveSessionState
    @State private var selectedProject: Project?
    @State private var showSettings = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            List {
                if store.projects.isEmpty {
                    emptyState
                } else {
                    Section {
                        ForEach(store.projects) { project in
                            ProjectRow(
                                project: project,
                                isSelected: selectedProject?.id == project.id,
                                onTap: { selectedProject = project }
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
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
                ToolbarItem(placement: .navigationBarLeading) {
                    if store.backendMode == .native {
                        Button { } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .disabled(true)
                        .opacity(0.3)
                    }
                }
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
            .onChange(of: selectedProject) { newProject in
                if let project = newProject {
                    sessionState.currentProject = project
                    Task { await store.selectProject(project) }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet(store: store)
            }
        }
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
            
            if store.backendMode == .unconfigured {
                Button("Configure") { }
                    .font(OCTypography.control)
                    .padding(.horizontal, OCSpacing.xl)
                    .padding(.vertical, OCSpacing.base)
                    .background(OCColor.agentBuild)
                    .foregroundColor(OCColor.bgDeep)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r24))
                    .disabled(true)
                    .opacity(0.3)
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
    
    public init(project: Project) {
        self.project = project
    }
    
    public var body: some View {
        List {
            Section {
                ForEach(store.sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: selectedSession?.id == session.id,
                        onTap: { selectedSession = session },
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
        .onChange(of: selectedSession) { newSession in
            if let session = newSession {
                sessionState.currentSession = session
                Task { await store.selectSession(session) }
            }
        }
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
                    Picker("Mode", selection: .constant(store.backendMode.rawValue)) {
                        Text("Remote (OpenCode Server)").tag(BackendMode.remote.rawValue)
                        Text("Native (Swift Sandbox)").tag(BackendMode.native.rawValue)
                    }
                    .disabled(true)
                    
                    if store.backendMode == .native {
                        NavigationLink("API Keys") {
                            APIKeysView()
                        }
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
        }
        .presentationDetents([.medium, .large])
    }
}

struct APIKeysView: View {
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
                    }
                }
            }
        }
    }
}