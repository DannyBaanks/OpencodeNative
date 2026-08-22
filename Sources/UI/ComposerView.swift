import SwiftUI

// MARK: - Composer View

public struct ComposerView: View {
    @EnvironmentObject private var sessionState: ActiveSessionState
    @FocusState private var isFocused: Bool

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Attachments row
            if !sessionState.composerAttachments.isEmpty {
                AttachmentsBar(attachments: sessionState.composerAttachments) { attachment in
                    sessionState.composerAttachments.removeAll { $0.id == attachment.id }
                }
                .padding(.horizontal, OCSpacing.contentMargin)
                .padding(.top, OCSpacing.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Input area
            HStack(alignment: .bottom, spacing: OCSpacing.base) {
                // Input text
                ZStack(alignment: .topLeading) {
                    if sessionState.composerText.isEmpty {
                        Text(sessionState.isProcessing ? "" : "Ask OpenCode…")
                            .font(OCTypography.body)
                            .foregroundColor(OCColor.textFaint)
                            .padding(.horizontal, OCSpacing.base)
                            .padding(.vertical, OCSpacing.sm)
                    }

                    TextField("", text: $sessionState.composerText, axis: .vertical)
                        .font(OCTypography.body)
                        .foregroundColor(OCColor.textPrimary)
                        .focused($isFocused)
                        .lineLimit(1...8)
                        .submitLabel(.send)
                        .onSubmit { handleSend() }
                        .disabled(sessionState.isProcessing)
                        .padding(.horizontal, OCSpacing.base)
                        .padding(.vertical, OCSpacing.sm)
                }
                .frame(minHeight: 42)

                // Send/Stop button
                SendStopButton(isProcessing: sessionState.isProcessing, agentColor: sessionState.agentMode.color) {
                    handleSend()
                }
            }
            .padding(.horizontal, OCSpacing.lg)
            .padding(.vertical, OCSpacing.base)

            // Control row
            ComposerControlRow(
                agentMode: sessionState.agentMode,
                onAgentTap: { sessionState.showAgentPicker = true },
                selectedModel: sessionState.selectedModel,
                onModelTap: { sessionState.showModelPicker = true },
                onAttachTap: { sessionState.showAttachments = true }
            )
            .padding(.horizontal, OCSpacing.contentMargin)
            .padding(.bottom, OCSpacing.base)
        }
        .background(
            RoundedRectangle(cornerRadius: OCRadius.r24)
                .fill(OCColor.bgBase.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: OCRadius.r24)
                        .stroke(OCColor.borderBase, lineWidth: 1)
                )
                .shadow(color: OCColor.shadowComposer.color, radius: OCColor.shadowComposer.radius, x: OCColor.shadowComposer.x, y: OCColor.shadowComposer.y)
        )
        .padding(.horizontal, OCSpacing.compactMargin)
        .padding(.bottom, OCSpacing.compactMargin)
        .animation(.easeInOut(duration: 0.18), value: sessionState.composerAttachments.isEmpty)
        .animation(.easeInOut(duration: 0.18), value: sessionState.isProcessing)
    }

    private func handleSend() {
        guard !sessionState.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // This will be handled by the parent view model
        NotificationCenter.default.post(name: .composerSend, object: sessionState.composerText)
        sessionState.composerText = ""
    }
}

// MARK: - Send/Stop Button

public struct SendStopButton: View {
    let isProcessing: Bool
    let agentColor: Color
    let action: () -> Void

    public init(isProcessing: Bool, agentColor: Color, action: @escaping () -> Void) {
        self.isProcessing = isProcessing
        self.agentColor = agentColor
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 32, height: 32)

                Image(systemName: iconName)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(iconColor)
            }
        }
        .disabled(isProcessing ? false : false) // Always enabled for stop
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isProcessing)
    }

    private var backgroundColor: Color {
        isProcessing ? agentColor.opacity(0.9) : OCColor.textPrimary
    }

    private var iconColor: Color {
        isProcessing ? OCColor.bgDeep : OCColor.bgBase
    }

    private var iconName: String {
        isProcessing ? "stop.fill" : "arrow.up"
    }

    private var iconSize: CGFloat {
        isProcessing ? 11 : 14
    }
}

// MARK: - Composer Control Row

public struct ComposerControlRow: View {
    let agentMode: AgentMode
    let onAgentTap: () -> Void
    let selectedModel: ModelInfo?
    let onModelTap: () -> Void
    let onAttachTap: () -> Void

    public init(
        agentMode: AgentMode,
        onAgentTap: @escaping () -> Void,
        selectedModel: ModelInfo?,
        onModelTap: @escaping () -> Void,
        onAttachTap: @escaping () -> Void
    ) {
        self.agentMode = agentMode
        self.onAgentTap = onAgentTap
        self.selectedModel = selectedModel
        self.onModelTap = onModelTap
        self.onAttachTap = onAttachTap
    }

    public var body: some View {
        HStack(spacing: OCSpacing.base) {
            // Attach button
            Button(action: onAttachTap) {
                Image(systemName: "paperclip")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(OCColor.iconPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Agent pill
            AgentPill(mode: agentMode, onTap: onAgentTap)

            // Model pill
            if let model = selectedModel {
                ModelPill(model: model, onTap: onModelTap)
            } else {
                ModelPillPlaceholder(onTap: onModelTap)
            }

            Spacer()
        }
        .frame(height: 32) // visible height
    }
}

// MARK: - Agent Pill

public struct AgentPill: View {
    let mode: AgentMode
    let onTap: () -> Void
    @State private var isPressed = false

    public init(mode: AgentMode, onTap: @escaping () -> Void) {
        self.mode = mode
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.xs) {
                // State dot
                Circle()
                    .fill(mode.color)
                    .frame(width: 6, height: 6)

                Text(mode.rawValue)
                    .font(OCTypography.pillLabel)
                    .foregroundColor(OCColor.textPrimary)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: OCRadius.r14)
                    .fill(mode.softColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: OCRadius.r14)
                            .stroke(mode.borderColor, lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .frame(height: 44) // hit target
        .contentShape(Rectangle())
    }
}

// MARK: - Model Pill

public struct ModelPill: View {
    let model: ModelInfo
    let onTap: () -> Void
    @State private var isPressed = false

    public init(model: ModelInfo, onTap: @escaping () -> Void) {
        self.model = model
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.xs) {
                if let icon = model.providerIcon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OCColor.iconPrimary)
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OCColor.iconPrimary)
                }

                Text(truncatedModelName)
                    .font(OCTypography.modelPillLabel)
                    .foregroundColor(OCColor.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .frame(maxWidth: 136)
            .background(
                RoundedRectangle(cornerRadius: OCRadius.r14)
                    .fill(OCColor.bgLayer1.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: OCRadius.r14)
                            .stroke(OCColor.borderMuted, lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    private var truncatedModelName: String {
        let name = model.name
        if name.count <= 18 { return name }
        let prefix = name.prefix(10)
        let suffix = name.suffix(6)
        return "\(prefix)…\(suffix)"
    }
}

// MARK: - Model Pill Placeholder

public struct ModelPillPlaceholder: View {
    let onTap: () -> Void

    public init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.xs) {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OCColor.iconMuted)

                Text("Select model")
                    .font(OCTypography.modelPillLabel)
                    .foregroundColor(OCColor.textFaint)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: OCRadius.r14)
                    .fill(OCColor.bgLayer1.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: OCRadius.r14)
                            .stroke(OCColor.borderMuted, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(height: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Attachments Bar

public struct AttachmentsBar: View {
    let attachments: [Attachment]
    let onRemove: (Attachment) -> Void

    public init(attachments: [Attachment], onRemove: @escaping (Attachment) -> Void) {
        self.attachments = attachments
        self.onRemove = onRemove
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OCSpacing.xs) {
                ForEach(attachments) { attachment in
                    AttachmentToken(attachment: attachment, onRemove: { onRemove(attachment) })
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 36)
    }
}

// MARK: - Agent Picker Sheet

public struct AgentPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedMode: AgentMode
    let availableModes: [AgentMode]

    public init(selectedMode: Binding<AgentMode>, availableModes: [AgentMode] = AgentMode.allCases) {
        self._selectedMode = selectedMode
        self.availableModes = availableModes
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Modes") {
                    ForEach(availableModes.prefix(2)) { mode in
                        AgentPickerRow(mode: mode, isSelected: selectedMode == mode) {
                            selectedMode = mode
                            dismiss()
                        }
                    }
                }

                if availableModes.count > 2 {
                    Section("Agents") {
                        ForEach(availableModes.dropFirst(2)) { mode in
                            AgentPickerRow(mode: mode, isSelected: selectedMode == mode) {
                                selectedMode = mode
                                dismiss()
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(OCColor.bgDeep)
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(CGFloat(availableModes.count * 56 + 120))])
    }
}

public struct AgentPickerRow: View {
    let mode: AgentMode
    let isSelected: Bool
    let onTap: () -> Void

    public init(mode: AgentMode, isSelected: Bool, onTap: @escaping () -> Void) {
        self.mode = mode
        self.isSelected = isSelected
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.base) {
                // State dot
                Circle()
                    .fill(mode.color)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.rawValue)
                        .font(.system(size: 15, weight: .medium, design: .default))
                        .foregroundColor(OCColor.textPrimary)

                    Text(mode.description)
                        .font(.system(size: 11.5, weight: .regular, design: .default))
                        .foregroundColor(OCColor.textFaint)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(mode.color)
                }
            }
            .padding(.vertical, OCSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Model Picker Sheet

public struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedModel: ModelInfo?
    let models: [ModelInfo]
    @State private var searchText = ""

    public init(selectedModel: Binding<ModelInfo?>, models: [ModelInfo] = ModelInfo.demoModels) {
        self._selectedModel = selectedModel
        self.models = models
    }

    public var body: some View {
        NavigationStack {
            List {
                // Search
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(OCColor.iconMuted)
                        TextField("Search models", text: $searchText)
                            .font(OCTypography.body)
                            .foregroundColor(OCColor.textPrimary)
                    }
                    .padding(OCSpacing.base)
                    .background(OCColor.bgLayer1)
                    .clipShape(RoundedRectangle(cornerRadius: OCRadius.r10))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                // Provider sections
                ForEach(groupedModels.keys.sorted(), id: \.self) { provider in
                    Section(header: ProviderHeader(provider: provider)) {
                        ForEach(groupedModels[provider] ?? []) { model in
                            ModelPickerRow(
                                model: model,
                                isSelected: selectedModel?.id == model.id
                            ) {
                                selectedModel = model
                                dismiss()
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(OCColor.bgDeep)
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var groupedModels: [String: [ModelInfo]] {
        Dictionary(grouping: filteredModels, by: { $0.provider })
    }

    private var filteredModels: [ModelInfo] {
        if searchText.isEmpty { return models }
        return models.filter { model in
            model.name.localizedCaseInsensitiveContains(searchText) ||
            model.provider.localizedCaseInsensitiveContains(searchText)
        }
    }
}

public struct ProviderHeader: View {
    let provider: String

    public var body: some View {
        Text(provider)
            .font(OCTypography.sectionLabel)
            .foregroundColor(OCColor.textFaint)
            .textCase(nil)
            .padding(.vertical, OCSpacing.xs)
    }
}

public struct ModelPickerRow: View {
    let model: ModelInfo
    let isSelected: Bool
    let onTap: () -> Void

    public init(model: ModelInfo, isSelected: Bool, onTap: @escaping () -> Void) {
        self.model = model
        self.isSelected = isSelected
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: OCSpacing.base) {
                if let icon = model.providerIcon {
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(OCColor.iconPrimary)
                        .frame(width: 32)
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(OCColor.iconMuted)
                        .frame(width: 32)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.system(size: 13.5, weight: .medium, design: .default))
                        .foregroundColor(OCColor.textPrimary)

                    HStack(spacing: OCSpacing.xs) {
                        if model.isLocal {
                            Label("Local", systemImage: "iphone")
                                .font(OCTypography.metaMono)
                                .foregroundColor(OCColor.agentExplore)
                        }
                        if model.supportsReasoning {
                            Label("Reasoning", systemImage: "brain")
                                .font(OCTypography.metaMono)
                                .foregroundColor(OCColor.agentBuild)
                        }
                        if model.supportsImages {
                            Label("Images", systemImage: "photo")
                                .font(OCTypography.metaMono)
                                .foregroundColor(OCColor.agentPlan)
                        }
                        if let ctx = model.contextWindow {
                            Text("\(ctx / 1000)k ctx")
                                .font(OCTypography.metaMono)
                                .foregroundColor(OCColor.textFaint)
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(OCColor.agentBuild)
                }
            }
            .padding(.vertical, OCSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let composerSend = Notification.Name("composerSend")
}