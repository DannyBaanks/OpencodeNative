import SwiftUI

// MARK: - User Prompt View

public struct UserPromptView: View {
    let event: TimelineEvent
    let agentColor: Color

    public init(event: TimelineEvent, agentColor: Color) {
        self.event = event
        self.agentColor = agentColor
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Rail
            RoundedRectangle(cornerRadius: 1)
                .fill(agentColor.opacity(0.8))
                .frame(width: 2)
                .frame(maxHeight: 72)

            VStack(alignment: .leading, spacing: 6) {
                // "you" label
                Text("you")
                    .font(OCTypography.metaMono)
                    .foregroundColor(OCColor.textFaint)

                // Prompt text
                if let text = event.promptText {
                    Text(text)
                        .font(OCTypography.userPrompt)
                        .foregroundColor(OCColor.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Attachments
                if let attachments = event.attachments, !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: OCSpacing.xs) {
                            ForEach(attachments) { attachment in
                                AttachmentToken(attachment: attachment)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, OCSpacing.xs)
    }
}

// MARK: - Assistant Text View

public struct AssistantTextView: View {
    let event: TimelineEvent

    public init(event: TimelineEvent) {
        self.event = event
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OCSpacing.base) {
            if let text = event.assistantText, !text.isEmpty {
                Text(text)
                    .font(OCTypography.body)
                    .foregroundColor(OCColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Attachment Token

public struct AttachmentToken: View {
    let attachment: Attachment
    let onRemove: (() -> Void)?

    public init(attachment: Attachment, onRemove: (() -> Void)? = nil) {
        self.attachment = attachment
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: OCSpacing.xs) {
            Image(systemName: attachment.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(OCColor.iconPrimary)

            Text(attachment.name)
                .font(OCTypography.modelPillLabel)
                .foregroundColor(OCColor.textPrimary)
                .lineLimit(1)

            if let onRemove = onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(OCColor.iconMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, OCSpacing.base)
        .frame(height: 28)
        .background(OCColor.bgLayer1)
        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r8))
        .overlay(
            RoundedRectangle(cornerRadius: OCRadius.r8)
                .stroke(OCColor.borderBase, lineWidth: 1)
        )
    }
}

// MARK: - Tool Call View (Collapsed)

public struct ToolCallCollapsedView: View {
    let event: TimelineEvent
    let agentColor: Color
    let onExpand: () -> Void

    public init(event: TimelineEvent, agentColor: Color, onExpand: @escaping () -> Void) {
        self.event = event
        self.agentColor = agentColor
        self.onExpand = onExpand
    }

    public var body: some View {
        HStack(spacing: OCSpacing.base) {
            // Status area
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 18, height: 18)

                if event.toolState == .running {
                    ProgressView()
                        .scaleEffect(0.6)
                        .progressViewStyle(CircularProgressViewStyle(tint: statusColor))
                } else {
                    Image(systemName: statusIcon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(statusColor)
                }
            }
            .frame(width: 18)

            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: OCSpacing.xs) {
                    Image(systemName: toolIcon(for: event.toolName))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OCColor.iconPrimary)

                    Text(event.toolName ?? "tool")
                        .font(OCTypography.toolLabel)
                        .foregroundColor(OCColor.textPrimary)

                    if let args = event.toolArguments, !args.isEmpty {
                        Text(args.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                            .font(OCTypography.toolDetail)
                            .foregroundColor(OCColor.textFaint)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Duration
            if let duration = event.toolDuration {
                Text(formatDuration(duration))
                    .font(OCTypography.metaMono)
                    .foregroundColor(OCColor.textFaint)
            }

            // Disclosure
            Button(action: onExpand) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(OCColor.iconMuted)
                    .rotationEffect(.degrees(event.isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.18), value: event.isExpanded)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 38)
        .background(
            event.toolState == .permission ? OCColor.warning.opacity(0.08) : Color.clear
        )
    }

    private var statusColor: Color {
        event.toolState?.color ?? agentColor
    }

    private var statusIcon: String {
        event.toolState?.icon ?? "circle.dotted"
    }

    private func toolIcon(for name: String?) -> String {
        guard let name = name?.lowercased() else { return "wrench" }
        if name.contains("read") { return "doc.text" }
        if name.contains("write") || name.contains("edit") { return "pencil" }
        if name.contains("bash") || name.contains("shell") { return "terminal" }
        if name.contains("glob") || name.contains("search") { return "magnifyingglass" }
        if name.contains("list") { return "list.bullet" }
        if name.contains("patch") || name.contains("diff") { return "arrow.left.arrow.right" }
        return "wrench"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 { return "\(Int(duration * 1000))ms" }
        if duration < 60 { return "\(Int(duration))s" }
        return "\(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s"
    }
}

// MARK: - Tool Call View (Expanded)

public struct ToolCallExpandedView: View {
    let event: TimelineEvent
    let agentColor: Color

    public init(event: TimelineEvent, agentColor: Color) {
        self.event = event
        self.agentColor = agentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: OCSpacing.base) {
                Image(systemName: toolIcon(for: event.toolName))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OCColor.iconPrimary)

                Text(event.toolName ?? "tool")
                    .font(OCTypography.toolLabel)
                    .foregroundColor(OCColor.textPrimary)

                Spacer()

                if let duration = event.toolDuration {
                    Text(formatDuration(duration))
                        .font(OCTypography.metaMono)
                        .foregroundColor(OCColor.textFaint)
                }

                if let state = event.toolState {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(state.color)
                            .frame(width: 6, height: 6)
                        Text(state.rawValue.capitalized)
                            .font(OCTypography.controlMono)
                            .foregroundColor(state.color)
                    }
                }
            }
            .padding(.horizontal, OCSpacing.base)
            .padding(.vertical, OCSpacing.sm)
            .frame(height: 34)
            .background(OCColor.bgBase)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(OCColor.borderBase),
                alignment: .bottom
            )

            // Output
            if let output = event.toolOutput, !output.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(output)
                        .font(OCTypography.codeSmall)
                        .foregroundColor(OCColor.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, OCSpacing.base)
                        .padding(.vertical, OCSpacing.xs)
                }
                .frame(maxHeight: 220)
            } else if event.toolState == .running {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                        .progressViewStyle(CircularProgressViewStyle(tint: agentColor))
                    Text("Running…")
                        .font(OCTypography.codeSmall)
                        .foregroundColor(OCColor.textFaint)
                }
                .padding(.horizontal, OCSpacing.base)
                .padding(.vertical, OCSpacing.xl)
            }
        }
        .ocCard(radius: OCRadius.r10, border: OCColor.borderBase, background: OCColor.bgBase)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func toolIcon(for name: String?) -> String {
        guard let name = name?.lowercased() else { return "wrench" }
        if name.contains("read") { return "doc.text" }
        if name.contains("write") || name.contains("edit") { return "pencil" }
        if name.contains("bash") || name.contains("shell") { return "terminal" }
        if name.contains("glob") || name.contains("search") { return "magnifyingglass" }
        if name.contains("list") { return "list.bullet" }
        if name.contains("patch") || name.contains("diff") { return "arrow.left.arrow.right" }
        return "wrench"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 { return "\(Int(duration * 1000))ms" }
        if duration < 60 { return "\(Int(duration))s" }
        return "\(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s"
    }
}

// MARK: - Tool Call Container

public struct ToolCallView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    let event: TimelineEvent
    let agentColor: Color

    public init(event: TimelineEvent, agentColor: Color) {
        self.event = event
        self.agentColor = agentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolCallCollapsedView(
                event: event,
                agentColor: agentColor,
                onExpand: { sessionState.toggleToolExpansion(id: event.id) }
            )

            if event.isExpanded {
                ToolCallExpandedView(event: event, agentColor: agentColor)
                    .padding(.top, OCSpacing.xs)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)).animation(.easeInOut(duration: 0.2)),
                        removal: .opacity.combined(with: .move(edge: .top)).animation(.easeInOut(duration: 0.15))
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: event.isExpanded)
    }
}

// MARK: - Diff View

public struct DiffView: View {
    let event: TimelineEvent

    public init(event: TimelineEvent) {
        self.event = event
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let files = event.diffFiles {
                ForEach(files) { file in
                    DiffFileView(file: file)
                        .padding(.bottom, OCSpacing.lg)
                }
            }
        }
    }
}

public struct DiffFileView: View {
    let file: DiffFile
    @State private var expandedHunks: Set<String> = []

    public init(file: DiffFile) {
        self.file = file
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File header
            HStack(spacing: OCSpacing.base) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OCColor.iconPrimary)

                Text(file.path)
                    .font(OCTypography.diffHeader)
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("+\(file.additions) −\(file.deletions)")
                    .font(OCTypography.diffHeader)
                    .foregroundColor(OCColor.textSecondary)

                // Actions
                HStack(spacing: OCSpacing.xs) {
                    Button("Open") { }
                        .font(OCTypography.controlMono)
                        .foregroundColor(OCColor.agentBuild)
                    Button("Unified") { }
                        .font(OCTypography.controlMono)
                        .foregroundColor(OCColor.textSecondary)
                }
            }
            .padding(.horizontal, OCSpacing.base)
            .padding(.vertical, OCSpacing.sm)
            .frame(height: 36)
            .background(OCColor.bgBase)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(OCColor.borderBase),
                alignment: .bottom
            )

            // Hunks
            ForEach(file.hunks) { hunk in
                DiffHunkView(hunk: hunk, isExpanded: expandedHunks.contains(hunk.id)) {
                    if expandedHunks.contains(hunk.id) {
                        expandedHunks.remove(hunk.id)
                    } else {
                        expandedHunks.insert(hunk.id)
                    }
                }
            }
        }
        .ocCard(radius: OCRadius.r12, border: OCColor.borderBase, background: OCColor.bgDeep)
    }
}

public struct DiffHunkView: View {
    let hunk: DiffHunk
    let isExpanded: Bool
    let onToggle: () -> Void

    public init(hunk: DiffHunk, isExpanded: Bool, onToggle: @escaping () -> Void) {
        self.hunk = hunk
        self.isExpanded = isExpanded
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hunk header
            Button(action: onToggle) {
                HStack {
                    Text(hunk.header)
                        .font(OCTypography.diffHeader)
                        .foregroundColor(OCColor.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(OCColor.iconMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, OCSpacing.base)
                .frame(height: 24)
                .background(OCColor.agentBuild.opacity(0.08))
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(hunk.lines) { line in
                    DiffLineView(line: line)
                }
            }
        }
    }
}

public struct DiffLineView: View {
    let line: DiffLine

    public init(line: DiffLine) {
        self.line = line
    }

    public var body: some View {
        HStack(alignment: .top, spacing: OCSpacing.xs) {
            // Line number gutter
            Text(line.number != nil ? "\(line.number!)" : "  ")
                .font(OCTypography.diffLineNum)
                .foregroundColor(OCColor.textFaint)
                .frame(width: 34, alignment: .trailing)

            Rectangle()
                .fill(OCColor.borderMuted)
                .frame(width: 0.5)

            // Content
            Text(line.content)
                .font(OCTypography.diffCode)
                .foregroundColor(lineColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, OCSpacing.xs)
                .padding(.vertical, 1)
        }
        .background(lineBackground)
    }

    private var lineColor: Color {
        switch line.kind {
        case .add: return OCColor.diffAddFg
        case .delete: return OCColor.diffDeleteFg
        case .hunk: return OCColor.textSecondary
        case .context: return OCColor.textPrimary
        }
    }

    private var lineBackground: Color {
        switch line.kind {
        case .add: return OCColor.diffAddBg
        case .delete: return OCColor.diffDeleteBg
        case .hunk: return OCColor.agentBuild.opacity(0.08)
        case .context: return Color.clear
        }
    }
}

// MARK: - Code Block View

public struct CodeBlockView: View {
    let event: TimelineEvent

    public init(event: TimelineEvent) {
        self.event = event
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if let lang = event.codeLanguage {
                    Text(lang)
                        .font(OCTypography.controlMono)
                        .foregroundColor(OCColor.textSecondary)
                }
                if let fileName = event.codeFileName {
                    Text(fileName)
                        .font(OCTypography.controlMono)
                        .foregroundColor(OCColor.textFaint)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = event.codeContent
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(OCColor.iconMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, OCSpacing.base)
            .frame(height: 30)
            .background(OCColor.bgBase)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(OCColor.borderBase),
                alignment: .bottom
            )

            // Code content
            ScrollView(.horizontal, showsIndicators: true) {
                Text(event.codeContent ?? "")
                    .font(OCTypography.code)
                    .foregroundColor(OCColor.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, OCSpacing.base)
                    .padding(.vertical, OCSpacing.xs)
            }
        }
        .ocCard(radius: OCRadius.r10, border: OCColor.borderBase, background: OCColor.bgBase)
    }
}

// MARK: - Thinking/Status View

public struct ThinkingView: View {
    let event: TimelineEvent
    let agentColor: Color

    public init(event: TimelineEvent, agentColor: Color) {
        self.event = event
        self.agentColor = agentColor
    }

    public var body: some View {
        HStack(spacing: OCSpacing.base) {
            // Activity indicator
            ZStack {
                Circle()
                    .stroke(agentColor.opacity(0.2), lineWidth: 2)
                    .frame(width: 16, height: 16)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(agentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: UUID())
            }

            Text(event.statusLabel ?? "Working")
                .font(OCTypography.control)
                .foregroundColor(OCColor.textSecondary)

            Spacer()

            if let elapsed = event.statusElapsed {
                Text(formatElapsed(elapsed))
                    .font(OCTypography.metaMono)
                    .foregroundColor(OCColor.textFaint)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 28)
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let secs = Int(interval)
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m \(secs % 60)s"
    }
}

// MARK: - Todo View

public struct TodoView: View {
    let event: TimelineEvent
    let agentColor: Color

    public init(event: TimelineEvent, agentColor: Color) {
        self.event = event
        self.agentColor = agentColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OCSpacing.xs) {
            if let items = event.todoItems {
                ForEach(items) { item in
                    TodoItemRow(item: item, agentColor: agentColor, indent: 0)
                }
            }
        }
        .padding(.vertical, OCSpacing.xs)
    }
}

public struct TodoItemRow: View {
    let item: TodoItem
    let agentColor: Color
    let indent: Int

    public init(item: TodoItem, agentColor: Color, indent: Int = 0) {
        self.item = item
        self.agentColor = agentColor
        self.indent = indent
    }

    public var body: some View {
        HStack(alignment: .top, spacing: OCSpacing.base) {
            // State glyph
            ZStack {
                if item.isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(OCColor.textFaint)
                } else if item.isRunning {
                    Circle()
                        .stroke(agentColor, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(agentColor)
                        .frame(width: 6, height: 6)
                } else {
                    Circle()
                        .stroke(OCColor.borderBase, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(OCTypography.todoText)
                    .foregroundColor(item.isCompleted ? OCColor.textFaint : OCColor.textPrimary)

                if let meta = item.metadata {
                    Text(meta)
                        .font(OCTypography.todoMeta)
                        .foregroundColor(OCColor.textFaint)
                }
            }

            Spacer()
        }
        .padding(.leading, CGFloat(indent) * 16)
        .frame(minHeight: 36)
    }
}

// MARK: - Permission View

public struct PermissionView: View {
    let event: TimelineEvent
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onPersistent: () -> Void

    public init(event: TimelineEvent, onAllow: @escaping () -> Void, onDeny: @escaping () -> Void, onPersistent: @escaping () -> Void) {
        self.event = event
        self.onAllow = onAllow
        self.onDeny = onDeny
        self.onPersistent = onPersistent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            // Header
            HStack(spacing: OCSpacing.base) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(OCColor.warning)

                Text("Permission Required")
                    .font(OCTypography.permissionTitle)
                    .foregroundColor(OCColor.textPrimary)
            }

            // Tool/Command
            if let tool = event.permissionTool, let command = event.permissionCommand {
                VStack(alignment: .leading, spacing: OCSpacing.xs) {
                    Text(tool)
                        .font(OCTypography.controlMono)
                        .foregroundColor(OCColor.agentBuild)

                    Text(command)
                        .font(OCTypography.codeSmall)
                        .foregroundColor(OCColor.textPrimary)
                        .padding(OCSpacing.base)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OCColor.bgDeep)
                        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r8))
                }
            }

            // Explanation
            if let explanation = event.permissionExplanation {
                Text(explanation)
                    .font(OCTypography.permissionBody)
                    .foregroundColor(OCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Scope
            if let scope = event.permissionScope {
                Text("Scope: \(scope)")
                    .font(OCTypography.metaMono)
                    .foregroundColor(OCColor.textFaint)
            }

            // Actions
            VStack(spacing: OCSpacing.base) {
                HStack(spacing: OCSpacing.base) {
                    Button(action: onDeny) {
                        Text("Deny")
                            .font(OCTypography.control)
                            .foregroundColor(OCColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(OCColor.bgLayer1)
                            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                            .overlay(
                                RoundedRectangle(cornerRadius: OCRadius.r10)
                                    .stroke(OCColor.borderBase, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: onAllow) {
                        Text("Allow Once")
                            .font(OCTypography.control)
                            .foregroundColor(OCColor.bgDeep)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(OCColor.agentBuild)
                            .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    Button("Always Allow", action: onPersistent)
                } label: {
                    Label("Persist Permission…", systemImage: "ellipsis.circle")
                        .font(OCTypography.control)
                        .foregroundColor(OCColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
            }
        }
        .padding(OCSpacing.lg)
        .ocCard(radius: OCRadius.r12, border: OCColor.warning.opacity(0.35), background: OCColor.bgBase)
    }
}

// MARK: - Question View

public struct QuestionView: View {
    let event: TimelineEvent
    let onSelect: (String) -> Void
    let onFreeform: (String) -> Void
    @State private var freeformText = ""

    public init(event: TimelineEvent, onSelect: @escaping (String) -> Void, onFreeform: @escaping (String) -> Void) {
        self.event = event
        self.onSelect = onSelect
        self.onFreeform = onFreeform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OCSpacing.lg) {
            Text(event.questionText ?? "Question")
                .font(OCTypography.permissionTitle)
                .foregroundColor(OCColor.textPrimary)

            if let choices = event.questionChoices {
                ForEach(choices) { choice in
                    Button {
                        onSelect(choice.id)
                    } label: {
                        HStack(spacing: OCSpacing.base) {
                            ZStack {
                                Circle()
                                    .stroke(OCColor.borderBase, lineWidth: 1.5)
                                    .frame(width: 20, height: 20)
                                if false { // selected state would be tracked
                                    Circle()
                                        .fill(OCColor.agentBuild)
                                        .frame(width: 10, height: 10)
                                }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.label)
                                    .font(OCTypography.questionChoice)
                                    .foregroundColor(OCColor.textPrimary)
                                if let desc = choice.description {
                                    Text(desc)
                                        .font(OCTypography.meta)
                                        .foregroundColor(OCColor.textFaint)
                                }
                            }

                            Spacer()
                        }
                        .padding(.horizontal, OCSpacing.base)
                        .frame(minHeight: 48)
                        .background(OCColor.bgLayer1.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                        .overlay(
                            RoundedRectangle(cornerRadius: OCRadius.r10)
                                .stroke(OCColor.borderBase, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if event.questionAllowFreeform == true {
                VStack(alignment: .leading, spacing: OCSpacing.xs) {
                    Text("Or type your answer:")
                        .font(OCTypography.meta)
                        .foregroundColor(OCColor.textFaint)

                    TextField("Your answer…", text: $freeformText, axis: .vertical)
                        .font(OCTypography.body)
                        .textFieldStyle(.plain)
                        .padding(OCSpacing.base)
                        .background(OCColor.bgLayer1)
                        .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                        .overlay(
                            RoundedRectangle(cornerRadius: OCRadius.r10)
                                .stroke(OCColor.borderBase, lineWidth: 1)
                        )
                        .lineLimit(3...6)

                    Button("Send") {
                        onFreeform(freeformText)
                        freeformText = ""
                    }
                    .font(OCTypography.control)
                    .foregroundColor(OCColor.bgDeep)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(freeformText.isEmpty ? OCColor.bgLayer2 : OCColor.agentBuild)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                    .disabled(freeformText.isEmpty)
                }
            }
        }
        .padding(OCSpacing.lg)
        .ocCard(radius: OCRadius.r12, border: OCColor.borderBase, background: OCColor.bgBase)
    }
}

// MARK: - System Message View

public struct SystemMessageView: View {
    let event: TimelineEvent

    public init(event: TimelineEvent) {
        self.event = event
    }

    public var body: some View {
        if let text = event.assistantText {
            Text(text)
                .font(OCTypography.meta)
                .foregroundColor(OCColor.textFaint)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, OCSpacing.xs)
        }
    }
}