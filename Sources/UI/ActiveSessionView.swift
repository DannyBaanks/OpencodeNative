import SwiftUI

public struct ActiveSessionView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var store: WorkbenchStore
    @State private var showDisconnectConfirm = false
    
    public init() {}
    
    // El switch vive en un @ViewBuilder propio: `Group { switch ... }` choca
    // con el overload `Group.init<R, C>(@TableColumnBuilder)` del iOS 26 SDK,
    // y un modificador colgado de un switch suelto no parsea como vista.
    @ViewBuilder private var surfaceContent: some View {
        switch sessionState.activeSurface {
        case .chat:
            ChatSurfaceView()
        case .files:
            FilesSurfaceView()
        case .review:
            ReviewSurfaceView()
        case .terminal:
            TerminalSurfaceView()
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Banner de conexion perdida: antes solo quedaba un evento en el
            // timeline y no existia forma de reconectar en caliente.
            if store.backendMode == .remote && store.connectionHealth == .disconnected {
                ConnectionLostBanner(
                    isReconnecting: store.isConnecting,
                    onReconnect: { Task { await store.reconnect() } }
                )
            }
            
            surfaceContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.18), value: sessionState.activeSurface)

            WorkSurfaceSwitcher(selectedSurface: $sessionState.activeSurface)
                .padding(.horizontal, OCSpacing.contentMargin)
                .padding(.vertical, OCSpacing.xs)

            ComposerView()
        }
        .background(OCColor.bgDeep.ignoresSafeArea())
        .navigationTitle(sessionState.currentSession?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack(spacing: OCSpacing.xs) {
                    // RootView intercambia vistas por estado (no hay push), asi que
                    // la salida de la sesion es explicita: currentSession = nil.
                    Button {
                        sessionState.currentSession = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(OCColor.iconPrimary)
                    }
                    
                    SessionNavTitle(
                        title: sessionState.currentSession?.title ?? "Session",
                        subtitle: sessionState.currentProject?.name ?? "Project"
                    )
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: OCSpacing.xs) {
                    if sessionState.activeSurface == .files {
                        Button { Task { await store.loadFiles() } } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 17))
                        }
                        .disabled(store.fileTree.isEmpty)
                    }
                    
                    if sessionState.activeSurface == .review {
                        Button { Task { await store.loadDiff(sessionID: sessionState.currentSession?.id ?? "") } } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 17))
                        }
                    }
                    
                    Button { showDisconnectConfirm = true } label: {
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
            AgentPickerSheet(selectedMode: $sessionState.agentMode, availableModes: availableModesForPicker)
        }
        .sheet(isPresented: $sessionState.showModelPicker) {
            ModelPickerSheet(selectedModel: $sessionState.selectedModel, models: store.availableModels.isEmpty ? ModelInfo.demoModels : store.availableModels)
        }
        .sheet(isPresented: $sessionState.showAttachments) {
            AttachmentsSheet()
                .environmentObject(store)
                .environmentObject(sessionState)
        }
        .sheet(item: $sessionState.pendingPermission) { event in
            PermissionView(
                event: event,
                onAllow: {
                    store.respondToPermission(requestId: event.permissionRequestId ?? event.id, decision: .allowOnce)
                },
                onDeny: {
                    store.respondToPermission(requestId: event.permissionRequestId ?? event.id, decision: .deny)
                },
                onPersistent: {
                    store.respondToPermission(requestId: event.permissionRequestId ?? event.id, decision: .allowAlways)
                }
            )
            .presentationDetents([.medium, .large])
            .interactiveDismissDisabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerSend)) { notification in
            if let text = notification.object as? String {
                store.sendPrompt(text)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerStop)) { _ in
            store.cancelCurrentRun()
        }
        .onChange(of: sessionState.activeSurface) { newSurface in
            if newSurface == .files {
                Task { await store.loadFiles() }
            } else if newSurface == .review, let sessionID = sessionState.currentSession?.id {
                Task { await store.loadDiff(sessionID: sessionID) }
            }
        }
        .onChange(of: sessionState.pendingPermission?.id) { _ in
            // Haptico al llegar una peticion de permiso (interaccion bloqueante).
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        .confirmationDialog(
            "Disconnect?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await store.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("End the session and return to the connection screen.")
        }
        .animation(.easeInOut(duration: 0.2), value: store.connectionHealth)
    }
    
    private var availableModesForPicker: [AgentMode] {
        if store.backendMode == .remote, !store.availableAgents.isEmpty {
            return store.availableAgents.compactMap { AgentMode(rawValue: $0) }
        }
        return AgentMode.allCases
    }
}

struct ChatSurfaceView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var store: WorkbenchStore
    @State private var scrollProxy: ScrollViewProxy?
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sessionState.timelineEvents.isEmpty {
                        EmptyChatView(sessionTitle: sessionState.currentSession?.title)
                    }
                    ForEach(sessionState.timelineEvents) { event in
                        TimelineEventContainer(event: event)
                            .id(event.id)
                    }
                }
                .padding(.horizontal, OCSpacing.contentMargin)
                .padding(.top, OCSpacing.lg)
                .padding(.bottom, OCSpacing.lg)
            }
            .onAppear { scrollProxy = proxy }
            .onChange(of: sessionState.timelineEvents.count) { _ in
                scrollToBottom()
            }
            .onChange(of: sessionState.isProcessing) { processing in
                if !processing { scrollToBottom() }
            }
        }
    }
    
    private func scrollToBottom() {
        guard let proxy = scrollProxy,
              let lastEvent = sessionState.timelineEvents.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(lastEvent.id, anchor: .bottom)
        }
    }
}

struct ConnectionLostBanner: View {
    let isReconnecting: Bool
    let onReconnect: () -> Void
    
    var body: some View {
        HStack(spacing: OCSpacing.base) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(OCColor.warning)
            
            Text(isReconnecting ? "Reconnecting…" : "Connection lost")
                .font(OCTypography.control)
                .foregroundColor(OCColor.textPrimary)
            
            Spacer()
            
            if isReconnecting {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Button("Reconnect", action: onReconnect)
                    .font(OCTypography.controlMono)
                    .foregroundColor(OCColor.warning)
            }
        }
        .padding(.horizontal, OCSpacing.contentMargin)
        .frame(height: 38)
        .background(OCColor.warning.opacity(0.10))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(OCColor.warning.opacity(0.30)),
            alignment: .bottom
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct EmptyChatView: View {
    let sessionTitle: String?
    
    var body: some View {
        VStack(spacing: OCSpacing.base) {
            Image(systemName: "bubble.left")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(OCColor.iconMuted)
            
            Text(sessionTitle ?? "Session")
                .font(OCTypography.bodyStrong)
                .foregroundColor(OCColor.textPrimary)
            
            Text("Send a message below to start")
                .font(OCTypography.meta)
                .foregroundColor(OCColor.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
    }
}

// `loadFiles(path:)` reemplaza el arbol completo al navegar una carpeta, asi
// que la barra de migas es la via de regreso a la raiz o a niveles superiores.
struct FilesBreadcrumbView: View {
    let path: String
    let onSelect: (String) -> Void
    
    // El server ecoa el separador del SO host ("/" en unix, "\" en Windows):
    // segmenta por ambos y conserva el prefijo crudo original para que el
    // drill-down use exactamente el path que devolvio el servidor.
    private var segments: [(label: String, subpath: String)] {
        var out: [(String, String)] = []
        var component = ""
        for index in path.indices {
            if path[index] == "/" || path[index] == "\\" {
                if !component.isEmpty {
                    out.append((component, String(path[path.startIndex..<index])))
                }
                component = ""
            } else {
                component.append(path[index])
            }
        }
        if !component.isEmpty {
            out.append((component, path))
        }
        return out
    }
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OCSpacing.xs) {
                Button("‹ root") { onSelect("") }
                    .font(OCTypography.controlMono)
                    .foregroundColor(OCColor.agentBuild)
                
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    Text("›")
                        .font(OCTypography.controlMono)
                        .foregroundColor(OCColor.textFaint)
                    
                    Button(segment.label) {
                        onSelect(segment.subpath)
                    }
                    .font(OCTypography.controlMono)
                    .foregroundColor(index == segments.count - 1 ? OCColor.textPrimary : OCColor.textSecondary)
                }
            }
            .padding(.horizontal, OCSpacing.contentMargin)
        }
        .frame(height: 34)
        .background(OCColor.bgBase)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(OCColor.borderMuted),
            alignment: .bottom
        )
    }
}

struct FilesSurfaceView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var selectedFile: WorkbenchFileNode?
    @State private var fileContent: WorkbenchFileContent?
    @State private var filesLoaded = false
    
    var body: some View {
        VStack(spacing: 0) {
            if !store.filesPath.isEmpty {
                FilesBreadcrumbView(path: store.filesPath) { newPath in
                    Task { await store.loadFiles(path: newPath) }
                }
            }
            
            if store.fileTree.isEmpty && filesLoaded {
                EmptyFilesView()
            } else {
                List {
                    ForEach(store.fileTree) { item in
                        FileTreeRowView(
                            item: item,
                            selectedFile: $selectedFile,
                            onTap: { file in
                                if !file.isDirectory {
                                    selectedFile = file
                                    Task {
                                        if let content = await store.loadFileContent(path: file.path) {
                                            fileContent = content
                                        }
                                    }
                                }
                            }
                        )
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(OCColor.bgDeep)
                .sheet(item: $selectedFile) { file in
                    FileViewerView(file: file, content: fileContent?.content ?? "")
                }
                .onAppear {
                    if !filesLoaded {
                        Task {
                            if store.fileTree.isEmpty {
                                await store.loadFiles()
                            }
                            filesLoaded = true
                        }
                    }
                }
            }
        }
    }
}

struct EmptyFilesView: View {
    var body: some View {
        VStack(spacing: OCSpacing.base) {
            Image(systemName: "folder")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(OCColor.iconMuted)
            
            Text("No files")
                .font(OCTypography.bodyStrong)
                .foregroundColor(OCColor.textPrimary)
            
            Text("This workspace has no visible files")
                .font(OCTypography.meta)
                .foregroundColor(OCColor.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileTreeRowView: View {
    @EnvironmentObject private var store: WorkbenchStore
    let item: WorkbenchFileNode
    @Binding var selectedFile: WorkbenchFileNode?
    let onTap: (WorkbenchFileNode) -> Void
    
    init(item: WorkbenchFileNode, selectedFile: Binding<WorkbenchFileNode?>, onTap: @escaping (WorkbenchFileNode) -> Void) {
        self.item = item
        self._selectedFile = selectedFile
        self.onTap = onTap
    }
    
    var body: some View {
        HStack(spacing: OCSpacing.xs) {
            // Las carpetas navegan (drill-down + breadcrumb); el Set de
            // expansion y el indent eran estado muerto: el arbol se reemplaza entero.
            if item.isDirectory {
                Button {
                    Task { await store.loadFiles(path: item.path) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(OCColor.iconMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 32)
            }
            
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.text")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(item.isDirectory ? OCColor.agentBuild : OCColor.iconPrimary)
            
            Text(item.name)
                .font(OCTypography.fileRow)
                .foregroundColor(OCColor.textPrimary)
                .lineLimit(1)
            
            if let status = item.status, status == "ignored" {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(OCColor.textFaint)
            }
            
            Spacer()
        }
        .padding(.horizontal, OCSpacing.contentMargin)
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap(item)
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

struct FileViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let file: WorkbenchFileNode
    let content: String
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content.isEmpty ? "Loading…" : content)
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
        }
    }
}

struct ReviewSurfaceView: View {
    @EnvironmentObject private var store: WorkbenchStore
    @State private var selectedDiff: SessionDiffFile?
    
    var body: some View {
        if store.diffFiles.isEmpty {
            EmptyReviewView()
        } else {
            List {
                ForEach(store.diffFiles) { diff in
                    Button {
                        selectedDiff = diff
                    } label: {
                        DiffFileRowView(diff: diff)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(OCColor.bgDeep)
            .sheet(item: $selectedDiff) { diff in
                DiffViewerView(diff: diff)
            }
        }
    }
}

struct EmptyReviewView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var store: WorkbenchStore
    
    var body: some View {
        VStack(spacing: OCSpacing.xl) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(OCColor.iconMuted)
            
            VStack(spacing: OCSpacing.xs) {
                Text("No Changes")
                    .font(OCTypography.bodyStrong)
                    .foregroundColor(OCColor.textPrimary)
                
                Text("No diff available for this session")
                    .font(OCTypography.meta)
                    .foregroundColor(OCColor.textFaint)
                    .multilineTextAlignment(.center)
            }
            
            Button("Refresh") {
                if let sessionID = sessionState.currentSession?.id {
                    Task { await store.loadDiff(sessionID: sessionID) }
                }
            }
            .font(OCTypography.control)
            .padding(.horizontal, OCSpacing.xl)
            .padding(.vertical, OCSpacing.base)
            .background(OCColor.agentBuild)
            .foregroundColor(OCColor.bgDeep)
            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r24))
        }
        .padding(OCSpacing.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DiffFileRowView: View {
    let diff: SessionDiffFile
    
    var body: some View {
        HStack(spacing: OCSpacing.base) {
            VStack(alignment: .leading, spacing: 2) {
                Text(diff.path)
                    .font(OCTypography.fileRow)
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                HStack(spacing: OCSpacing.sm) {
                    if diff.additions > 0 {
                        Label("+\(diff.additions)", systemImage: "plus")
                            .font(OCTypography.metaMono)
                            .foregroundColor(OCColor.diffAddFg)
                    }
                    if diff.deletions > 0 {
                        Label("-\(diff.deletions)", systemImage: "minus")
                            .font(OCTypography.metaMono)
                            .foregroundColor(OCColor.diffDeleteFg)
                    }
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(OCColor.iconMuted)
        }
        .padding(.horizontal, OCSpacing.contentMargin)
        .padding(.vertical, OCSpacing.lg)
        .background(Color.clear)
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

struct DiffViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let diff: SessionDiffFile

    private var lines: [DiffLine] {
        UnifiedDiffBuilder.lines(before: diff.before ?? "", after: diff.after ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(diff.path)
                    .font(OCTypography.diffHeader)
                    .foregroundColor(OCColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, OCSpacing.contentMargin)
                    .padding(.vertical, OCSpacing.base)

                Divider().overlay(OCColor.borderBase)

                ScrollView(.horizontal, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            DiffLineView(line: line)
                        }
                    }
                    .padding(.horizontal, OCSpacing.contentMargin)
                    .padding(.vertical, OCSpacing.base)
                }
                .textSelection(.enabled)
            }
            .background(OCColor.bgDeep)
            .navigationTitle("Diff")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(OCColor.bgDeep, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

/// Builds a unified, line-level diff (add/delete/context) from full before/after
/// file snapshots. Uses LCS to align lines so the Review surface reads as a
/// real developer diff, not two decorative before/after blocks.
struct UnifiedDiffBuilder {
    static func lines(before: String, after: String) -> [DiffLine] {
        let a = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let b = after.isEmpty ? [] : after.components(separatedBy: "\n")
        let n = a.count
        let m = b.count

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }

        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                result.append(DiffLine(kind: .context, content: a[i]))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                result.append(DiffLine(kind: .delete, content: a[i]))
                i += 1
            } else {
                result.append(DiffLine(kind: .add, content: b[j]))
                j += 1
            }
        }
        while i < n {
            result.append(DiffLine(kind: .delete, content: a[i]))
            i += 1
        }
        while j < m {
            result.append(DiffLine(kind: .add, content: b[j]))
            j += 1
        }
        return result
    }
}

struct TerminalSurfaceView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    @EnvironmentObject private var store: WorkbenchStore
    @State private var command = ""
    @FocusState private var isFocused: Bool
    @State private var output: [TerminalOutput] = []
    
    var body: some View {
        ZStack {
            OCColor.bgDeep.ignoresSafeArea()
            
            VStack(spacing: 0) {
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
                
                HStack(spacing: OCSpacing.base) {
                    Text("$")
                        .font(OCTypography.code)
                        .foregroundColor(OCColor.iconMuted)
                    
                    TextField("command", text: $command)
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    output.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundColor(OCColor.iconMuted)
                }
            }
        }
        .onAppear {
            if output.isEmpty {
                output.append(TerminalOutput(text: "OpenCodeNative Terminal — commands run via OpenCode server", color: OCColor.textFaint))
                output.append(TerminalOutput(text: "Type a command and press Enter", color: OCColor.textFaint))
                output.append(TerminalOutput(text: "", color: OCColor.textPrimary))
            }
        }
    }
    
    private func executeCommand() {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        
        output.append(TerminalOutput(text: "$ \(cmd)", color: OCColor.textSecondary))
        command = ""
        
        let agent = sessionState.agentMode.rawValue.lowercased()
        Task {
            await store.runShellCommand(cmd, agent: agent)
            if let last = store.shellHistory.last {
                for text in last.result?.textParts ?? [] {
                    output.append(TerminalOutput(text: text, color: OCColor.textPrimary))
                }
                if let error = last.result?.error {
                    output.append(TerminalOutput(text: "Error: \(error)", color: OCColor.danger))
                }
                output.append(TerminalOutput(text: "", color: OCColor.textPrimary))
            }
        }
    }
}

struct TerminalOutput: Identifiable {
    let id = UUID().uuidString
    let text: String
    let color: Color
}

// MARK: - Session Nav Title

struct SessionNavTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(OCTypography.navTitle)
                .foregroundColor(OCColor.textPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(OCTypography.navSubtitle)
                .foregroundColor(OCColor.textFaint)
                .lineLimit(1)
        }
    }
}

// MARK: - Work Surface Switcher

struct WorkSurfaceSwitcher: View {
    @Binding var selectedSurface: WorkSurface

    var body: some View {
        HStack(spacing: OCSpacing.sm) {
            ForEach(WorkSurface.allCases) { surface in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    selectedSurface = surface
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: surface.icon)
                            .font(.system(size: 13, weight: .medium))
                        Text(surface.rawValue)
                            .font(OCTypography.control)
                    }
                    .foregroundColor(selectedSurface == surface ? OCColor.textPrimary : OCColor.textFaint)
                    .padding(.horizontal, OCSpacing.lg)
                    .frame(height: 32)
                    .background(
                        selectedSurface == surface ? OCColor.bgLayer1 : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                }
                .buttonStyle(.plain)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
        }
    }
}
