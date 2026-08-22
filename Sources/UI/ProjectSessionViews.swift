import SwiftUI

// MARK: - Project Row

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
                // Avatar
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

                // Trailing
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

// MARK: - Project List View

public struct ProjectListView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    @State private var projects: [Project] = Project.demoProjects
    @State private var selectedProject: Project?
    @State private var showNewProjectSheet = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(projects) { project in
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

                if projects.isEmpty {
                    emptyState
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(OCColor.bgDeep)
            .navigationTitle("OpenCode")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showNewProjectSheet = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { } label: {
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
                    // Navigate to session list would happen via NavigationLink in real implementation
                }
            }
            .sheet(isPresented: $showNewProjectSheet) {
                NewProjectSheet()
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

                Text("Open a project to start a session")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textFaint)
                    .multilineTextAlignment(.center)
            }

            Button("Open Project") { showNewProjectSheet = true }
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

// MARK: - Session Row

public struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let onTap: () -> Void

    public init(session: Session, isSelected: Bool = false, onTap: @escaping () -> Void) {
        self.session = session
        self.isSelected = isSelected
        self.onTap = onTap
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

                        // Agent mode dot
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
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(OCColor.borderMuted),
            alignment: .bottom
        )
    }
}

// MARK: - Session List View

public struct SessionListView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    let project: Project
    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
    @State private var showNewSessionSheet = false

    public init(project: Project) {
        self.project = project
    }

    public var body: some View {
        List {
            Section {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: selectedSession?.id == session.id,
                        onTap: { selectedSession = session }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
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

            if sessions.isEmpty {
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
        .onAppear {
            sessions = Session.demoSessions(for: project)
        }
        .onChange(of: selectedSession) { newSession in
            if let session = newSession {
                sessionState.currentSession = session
            }
        }
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionSheet(project: project)
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

// MARK: - New Project Sheet

private struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Project Details") {
                    TextField("Name", text: $name)
                    TextField("Path", text: $path)
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { dismiss() }
                        .disabled(name.isEmpty || path.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - New Session Sheet

private struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
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
                    Button("Create") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}