import SwiftUI

// MARK: - Active Session View

public struct ActiveSessionView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var sessionAdapter: SessionAdapter
    @State private var scrollProxy: ScrollViewProxy?
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var isComposerFocused: Bool

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Background
            OCColor.bgDeep.ignoresSafeArea()

            // Timeline
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sessionState.timelineEvents) { event in
                            TimelineEventContainer(event: event)
                                .id(event.id)
                        }
                    }
                    .padding(.horizontal, OCSpacing.contentMargin)
                    .padding(.top, OCSpacing.lg)
                    .padding(.bottom, composerHeight + OCSpacing.lg)
                }
                .onAppear { scrollProxy = proxy }
                .onChange(of: sessionState.timelineEvents.count) { _ in
                    scrollToBottom()
                }
                .onChange(of: sessionState.isProcessing) { processing in
                    if !processing { scrollToBottom() }
                }
                .onChange(of: sessionState.selectedModel) { model in
                    if let model = model {
                        sessionAdapter.setModel(model)
                    }
                }
            }

            // Composer - floating at bottom
            VStack(spacing: 0) {
                // Work surface switcher (condensed)
                WorkSurfaceSwitcher(selectedSurface: $sessionState.activeSurface)
                    .padding(.horizontal, OCSpacing.contentMargin)
                    .padding(.top, OCSpacing.xs)

                ComposerView()
            }
        }
        .navigationTitle(sessionState.currentSession?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                SessionNavTitle(
                    title: sessionState.currentSession?.title ?? "Session",
                    subtitle: sessionState.currentProject?.name ?? "Project"
                )
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: OCSpacing.xs) {
                    Button { } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 17))
                    }
                    Button { sessionAdapter.disconnect() } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 17))
                    }
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $sessionState.showAgentPicker) {
            AgentPickerSheet(selectedMode: $sessionState.agentMode)
        }
        .sheet(isPresented: $sessionState.showModelPicker) {
            ModelPickerSheet(selectedModel: $sessionState.selectedModel)
        }
        .sheet(item: $sessionState.pendingPermission) { event in
            PermissionView(
                event: event,
                onAllow: {
                    sessionAdapter.respondToPermission(
                        requestId: event.permissionRequestId ?? event.id,
                        decision: .allowOnce
                    )
                },
                onDeny: {
                    sessionAdapter.respondToPermission(
                        requestId: event.permissionRequestId ?? event.id,
                        decision: .deny
                    )
                },
                onPersistent: {
                    sessionAdapter.respondToPermission(
                        requestId: event.permissionRequestId ?? event.id,
                        decision: .allowAlways
                    )
                }
            )
            .presentationDetents([.medium, .large])
            .interactiveDismissDisabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerSend)) { notification in
            if let text = notification.object as? String {
                sessionAdapter.sendPrompt(text)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerStop)) { _ in
            sessionAdapter.cancelCurrentRun()
        }
    }

    private var composerHeight: CGFloat {
        // Estimate based on content - in real implementation this would be measured
        140 + (sessionState.composerAttachments.isEmpty ? 0 : 44)
    }

    private func scrollToBottom() {
        guard let proxy = scrollProxy,
              let lastEvent = sessionState.timelineEvents.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(lastEvent.id, anchor: .bottom)
        }
    }
}

// MARK: - Timeline Event Container

struct TimelineEventContainer: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var sessionAdapter: SessionAdapter
    let event: TimelineEvent

    var body: some View {
        VStack(alignment: .leading, spacing: OCSpacing.timelineBlockGap) {
            switch event.kind {
            case .userPrompt:
                UserPromptView(event: event, agentColor: event.agentMode?.color ?? OCColor.agentBuild)

            case .assistantText:
                AssistantTextView(event: event)

            case .toolCall, .toolResult:
                ToolCallView(event: event, agentColor: event.agentMode?.color ?? OCColor.agentBuild)

            case .diff:
                DiffView(event: event)

            case .codeBlock:
                CodeBlockView(event: event)

            case .permission:
                PermissionView(
                    event: event,
                    onAllow: {
                        sessionAdapter.respondToPermission(requestId: event.permissionRequestId ?? event.id, decision: .allowOnce)
                    },
                    onDeny: {
                        sessionAdapter.respondToPermission(requestId: event.permissionRequestId ?? event.id, decision: .deny)
                    },
                    onPersistent: {
                        sessionAdapter.respondToPermission(requestId: event.permissionRequestId ?? event.id, decision: .allowAlways)
                    }
                )

            case .question:
                QuestionView(
                    event: event,
                    onSelect: { _ in /* handle select */ },
                    onFreeform: { _ in /* handle freeform */ }
                )

            case .thinking:
                ThinkingView(event: event, agentColor: event.agentMode?.color ?? OCColor.agentBuild)

            case .todo:
                TodoView(event: event, agentColor: event.agentMode?.color ?? OCColor.agentBuild)

            case .system:
                SystemMessageView(event: event)
            }
        }
        .padding(.bottom, OCSpacing.timelineEventGap)
    }
}

// MARK: - Session Navigation Title

struct SessionNavTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(title)
                .font(OCTypography.navTitle)
                .foregroundColor(OCColor.textPrimary)
                .lineLimit(1)

            Text(subtitle)
                .font(OCTypography.navSubtitle)
                .foregroundColor(OCColor.textFaint)
                .lineLimit(1)
        }
        .frame(maxWidth: 238)
    }
}

// MARK: - Work Surface Switcher

struct WorkSurfaceSwitcher: View {
    @Binding var selectedSurface: WorkSurface

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OCSpacing.xs) {
                ForEach(WorkSurface.allCases) { surface in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedSurface = surface
                        }
                    } label: {
                        HStack(spacing: OCSpacing.xs) {
                            Image(systemName: surface.icon)
                                .font(.system(size: 14, weight: .medium))
                            Text(surface.rawValue)
                                .font(OCTypography.control)
                        }
                        .foregroundColor(selectedSurface == surface ? OCColor.bgDeep : OCColor.textPrimary)
                        .padding(.horizontal, OCSpacing.base)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: OCRadius.r14)
                                .fill(selectedSurface == surface ? OCColor.agentBuild : OCColor.bgLayer1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: OCRadius.r14)
                                        .stroke(selectedSurface == surface ? Color.clear : OCColor.borderBase, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 36)
    }
}

// MARK: - Terminal View

public struct TerminalView: View {
    @State private var output: [TerminalLine] = []
    @State private var input = ""
    @FocusState private var isFocused: Bool

    public init() {}

    public var body: some View {
        ZStack {
            OCColor.bgDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                // Terminal content
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(output) { line in
                                Text(line.text)
                                    .font(OCTypography.code)
                                    .foregroundColor(line.color)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, OCSpacing.lg)
                                    .padding(.vertical, 1)
                                    .id(line.id)
                            }
                        }
                        .padding(.vertical, OCSpacing.base)
                    }
                    .onChange(of: output.count) { _ in
                        if let last = output.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                // Input line
                HStack(spacing: OCSpacing.base) {
                    Text("$")
                        .font(OCTypography.code)
                        .foregroundColor(OCColor.iconMuted)

                    TextField("command", text: $input)
                        .font(OCTypography.code)
                        .foregroundColor(OCColor.textPrimary)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .submitLabel(.send)
                        .onSubmit { executeCommand() }
                }
                .padding(.horizontal, OCSpacing.lg)
                .padding(.vertical, OCSpacing.base)
                .background(OCColor.bgBase)
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(OCColor.borderBase),
                    alignment: .top
                )
            }
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(OCColor.bgDeep, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            output.append(TerminalLine(text: "Welcome to OpenCodeNative Terminal", color: OCColor.textFaint))
            output.append(TerminalLine(text: "Type 'help' for available commands", color: OCColor.textFaint))
            output.append(TerminalLine(text: "", color: OCColor.textPrimary))
        }
    }

    private func executeCommand() {
        let cmd = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }

        output.append(TerminalLine(text: "$ \(cmd)", color: OCColor.textSecondary))
        input = ""

        // Simulate command output
        if cmd == "help" {
            output.append(TerminalLine(text: "Available commands:", color: OCColor.textPrimary))
            output.append(TerminalLine(text: "  help     - Show this help", color: OCColor.textPrimary))
            output.append(TerminalLine(text: "  ls       - List files", color: OCColor.textPrimary))
            output.append(TerminalLine(text: "  pwd      - Print working directory", color: OCColor.textPrimary))
            output.append(TerminalLine(text: "  clear    - Clear terminal", color: OCColor.textPrimary))
        } else if cmd == "clear" {
            output.removeAll()
        } else if cmd == "pwd" {
            output.append(TerminalLine(text: "/Users/user/Development/OpencodeNative", color: OCColor.textPrimary))
        } else if cmd == "ls" {
            output.append(TerminalLine(text: "App/          Sources/        Tests/", color: OCColor.textPrimary))
            output.append(TerminalLine(text: "Assets.xcassets/  project.yml   README.md", color: OCColor.textPrimary))
        } else {
            output.append(TerminalLine(text: "Command not found: \(cmd)", color: OCColor.danger))
        }

        output.append(TerminalLine(text: "", color: OCColor.textPrimary))
    }
}

struct TerminalLine: Identifiable {
    let id = UUID().uuidString
    let text: String
    let color: Color
}

// MARK: - Files View

public struct FilesView: View {
    @State private var expandedFolders: Set<String> = []
    @State private var selectedFile: FileItem?

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                ForEach(rootItems) { item in
                    FileRowView(item: item, expandedFolders: $expandedFolders, selectedFile: $selectedFile, indent: 0)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(OCColor.bgDeep)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(OCColor.bgDeep, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(item: $selectedFile) { file in
                FileViewerView(file: file)
            }
        }
    }

    private var rootItems: [FileItem] {
        [
            FileItem(name: "App", path: "App", isDirectory: true, children: [
                FileItem(name: "OpencodeNativeApp.swift", path: "App/OpencodeNativeApp.swift", isDirectory: false)
            ]),
            FileItem(name: "Sources", path: "Sources", isDirectory: true, children: [
                FileItem(name: "UI", path: "Sources/UI", isDirectory: true, children: [
                    FileItem(name: "SessionViewModel.swift", path: "Sources/UI/SessionViewModel.swift", isDirectory: false),
                    FileItem(name: "ConsoleView.swift", path: "Sources/UI/ConsoleView.swift", isDirectory: false),
                    FileItem(name: "DesignSystem.swift", path: "Sources/UI/DesignSystem.swift", isDirectory: false),
                    FileItem(name: "Models.swift", path: "Sources/UI/Models.swift", isDirectory: false),
                    FileItem(name: "TimelineViews.swift", path: "Sources/UI/TimelineViews.swift", isDirectory: false),
                    FileItem(name: "ComposerView.swift", path: "Sources/UI/ComposerView.swift", isDirectory: false),
                    FileItem(name: "ActiveSessionView.swift", path: "Sources/UI/ActiveSessionView.swift", isDirectory: false),
                    FileItem(name: "ProjectSessionViews.swift", path: "Sources/UI/ProjectSessionViews.swift", isDirectory: false),
                ]),
                FileItem(name: "Agent", path: "Sources/Agent", isDirectory: true, children: [
                    FileItem(name: "AgentLoop.swift", path: "Sources/Agent/AgentLoop.swift", isDirectory: false)
                ]),
                FileItem(name: "Model", path: "Sources/Model", isDirectory: true, children: [
                    FileItem(name: "ModelProvider.swift", path: "Sources/Model/ModelProvider.swift", isDirectory: false),
                    FileItem(name: "ScriptedModelProvider.swift", path: "Sources/Model/ScriptedModelProvider.swift", isDirectory: false)
                ]),
                FileItem(name: "Workspace", path: "Sources/Workspace", isDirectory: true, children: [
                    FileItem(name: "Workspace.swift", path: "Sources/Workspace/Workspace.swift", isDirectory: false)
                ]),
                FileItem(name: "Persistence", path: "Sources/Persistence", isDirectory: true, children: [
                    FileItem(name: "Persistence.swift", path: "Sources/Persistence/Persistence.swift", isDirectory: false)
                ]),
                FileItem(name: "Tools", path: "Sources/Tools", isDirectory: true, children: [
                    FileItem(name: "FileSystemTools.swift", path: "Sources/Tools/FileSystemTools.swift", isDirectory: false),
                    FileItem(name: "GlobMatcher.swift", path: "Sources/Tools/GlobMatcher.swift", isDirectory: false)
                ]),
                FileItem(name: "Host", path: "Sources/Host", isDirectory: true, children: [
                    FileItem(name: "OpenCodeRuntimeContract.swift", path: "Sources/Host/OpenCodeRuntimeContract.swift", isDirectory: false),
                    FileItem(name: "IOSCapabilityMatrix.swift", path: "Sources/Host/IOSCapabilityMatrix.swift", isDirectory: false),
                    FileItem(name: "CompatibilityReport.swift", path: "Sources/Host/CompatibilityReport.swift", isDirectory: false),
                    FileItem(name: "OpenCodeBootAttempt.swift", path: "Sources/Host/OpenCodeBootAttempt.swift", isDirectory: false)
                ])
            ]),
            FileItem(name: "Tests", path: "Tests", isDirectory: true, children: [
                FileItem(name: "GlobMatcherTests.swift", path: "Tests/GlobMatcherTests.swift", isDirectory: false),
                FileItem(name: "HostTests.swift", path: "Tests/HostTests.swift", isDirectory: false),
                FileItem(name: "CoreEndToEndTests.swift", path: "Tests/CoreEndToEndTests.swift", isDirectory: false)
            ]),
            FileItem(name: "project.yml", path: "project.yml", isDirectory: false),
            FileItem(name: "README.md", path: "README.md", isDirectory: false),
            FileItem(name: "Info.plist", path: "Info.plist", isDirectory: false),
            FileItem(name: "LICENSE", path: "LICENSE", isDirectory: false)
        ]
    }
}

public struct FileItem: Identifiable, Hashable {
    public let id = UUID().uuidString
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileItem]?

    public init(name: String, path: String, isDirectory: Bool, children: [FileItem]? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.children = children
    }
}

struct FileRowView: View {
    let item: FileItem
    @Binding var expandedFolders: Set<String>
    @Binding var selectedFile: FileItem?
    let indent: Int

    var body: some View {
        HStack(spacing: OCSpacing.xs) {
            // Indent
            if indent > 0 {
                Spacer().frame(width: CGFloat(indent) * 16)
            }

            // Disclosure
            if item.isDirectory {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expandedFolders.contains(item.path) {
                            expandedFolders.remove(item.path)
                        } else {
                            expandedFolders.insert(item.path)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(OCColor.iconMuted)
                        .rotationEffect(.degrees(expandedFolders.contains(item.path) ? 90 : 0))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 32)
            }

            // Icon
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.text")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(item.isDirectory ? OCColor.agentBuild : OCColor.iconPrimary)

            // Name
            Text(item.name)
                .font(OCTypography.fileRow)
                .foregroundColor(OCColor.textPrimary)
                .lineLimit(1)

            Spacer()

            // Dirty indicator would go here
        }
        .padding(.horizontal, OCSpacing.contentMargin)
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            if !item.isDirectory {
                selectedFile = item
            }
        }
        .background(
            selectedFile?.id == item.id ? OCColor.bgLayer1.opacity(0.5) : Color.clear
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(OCColor.borderMuted),
            alignment: .bottom
        )
    }
}

// MARK: - File Viewer

struct FileViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let file: FileItem
    @State private var content = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content.isEmpty ? "Loadingâ€¦" : content)
                    .font(OCTypography.code)
                    .foregroundColor(OCColor.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OCSpacing.lg)
            }
            .background(OCColor.bgDeep)
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(file.path)
                        .font(OCTypography.metaMono)
                        .foregroundColor(OCColor.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: OCSpacing.base) {
                        Button {
                            UIPasteboard.general.string = content
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 17))
                        }
                        Button("Done") { dismiss() }
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(OCColor.bgDeep, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { loadContent() }
        }
    }

    private func loadContent() {
        // In real implementation, read from workspace
        content = "// \(file.name)\n// Path: \(file.path)\n\n// File content would be loaded from the workspace\n// This is a placeholder for the file viewer implementation"
    }
}
