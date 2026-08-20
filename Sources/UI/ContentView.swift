import SwiftUI
import Combine

/// Vista principal de la app
public struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isInputFocused: Bool
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header con estado
                headerView
                
                Divider()
                
                // Área de conversación
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                MessageView(message: message)
                                    .id(message.id)
                            }
                            
                            if viewModel.isProcessing {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Procesando...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages.count) { _, _ in
                        if let last = viewModel.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                
                Divider()
                
                // Input area
                inputArea
            }
            .navigationTitle("OpencodeNative")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button("Nueva conversación") { viewModel.newConversation() }
                        Button("Workspace") { viewModel.showWorkspacePicker = true }
                        Divider()
                        Button("Configuración") { viewModel.showSettings = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        // Status indicator
                        Circle()
                            .fill(viewModel.isProcessing ? .orange : .green)
                            .frame(width: 8, height: 8)
                        
                        Button {
                            viewModel.showCapabilities = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $viewModel.showWorkspacePicker) {
                WorkspacePickerView(workspace: viewModel.workspace, selectedPath: $viewModel.workspacePath)
            }
            .sheet(isPresented: $viewModel.showSettings) {
                SettingsView(config: $viewModel.config)
            }
            .sheet(isPresented: $viewModel.showCapabilities) {
                CapabilitiesView()
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil), actions: {
                Button("OK") { viewModel.errorMessage = nil }
            }, message: {
                Text(viewModel.errorMessage ?? "")
            })
            .task {
                await viewModel.initialize()
            }
        }
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.workspacePath.isEmpty ? "Sin workspace" : viewModel.workspacePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            
            if viewModel.isProcessing {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
    
    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Mensaje...", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onSubmit { viewModel.sendMessage() }
            
            Button(action: viewModel.sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .blue)
            }
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isProcessing)
        }
        .padding()
        .background(.regularMaterial)
    }
}

/// Vista de un mensaje individual
private struct MessageView: View {
    let message: Message
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header del mensaje
            HStack {
                Image(systemName: message.role.icon)
                    .foregroundStyle(message.role.color)
                Text(message.role.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            
            // Contenido
            if message.role == .tool {
                ToolMessageView(message: message)
            } else {
                Text(message.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Tool calls
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                ToolCallsView(toolCalls: toolCalls)
            }
            
            // Tool results
            if let toolResults = message.toolResults, !toolResults.isEmpty {
                ToolResultsView(toolResults: toolResults)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ToolMessageView: View {
    let message: Message
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let toolResults = message.toolResults {
                ForEach(toolResults) { result in
                    HStack {
                        Image(systemName: result.error != nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(result.error != nil ? .red : .green)
                        Text(result.output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                    .padding(8)
                    .background(result.error != nil ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Text(message.content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ToolCallsView: View {
    let toolCalls: [ToolCall]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(toolCalls) { call in
                HStack {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(call.name)
                            .font(.caption.weight(.medium))
                        if !call.arguments.isEmpty {
                            Text(call.arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .padding(8)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

private struct ToolResultsView: View {
    let toolResults: [ToolResult]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(toolResults) { result in
                HStack {
                    Image(systemName: result.error != nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(result.error != nil ? .red : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                        if let error = result.error {
                            Text("Error: \(error)")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(8)
                .background(result.error != nil ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Picker de workspace
struct WorkspacePickerView: View {
    let workspace: any Workspace
    @Binding var selectedPath: String
    @Environment(\.dismiss) var dismiss
    @State private var currentPath = ""
    @State private var items: [FileInfo] = []
    @State private var error: String?
    
    var body: some View {
        NavigationStack {
            List {
                if !currentPath.isEmpty {
                    Button(".. (subir)") {
                        Task { await navigateUp() }
                    }
                    .foregroundStyle(.blue)
                }
                
                ForEach(items) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(item.isDirectory ? .blue : .secondary)
                        VStack(alignment: .leading) {
                            Text(item.name)
                                .font(.body)
                            Text("\(item.size) bytes • \(item.modificationDate, style: .relative)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task {
                            if item.isDirectory {
                                await navigateInto(item.name)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Seleccionar como workspace") {
                            selectedPath = currentPath.isEmpty ? item.name : "\(currentPath)/\(item.name)"
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Usar actual") {
                        selectedPath = currentPath
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Crear directorio") { Task { await createDirectory() } }
                }
            }
            .task { await loadCurrent() }
            .alert("Error", isPresented: .constant(error != nil), actions: {
                Button("OK") { error = nil }
            }, message: { Text(error ?? "") })
        }
    }
    
    private func loadCurrent() async {
        do {
            items = try await workspace.listDirectory(at: currentPath)
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    private func navigateInto(_ name: String) async {
        let newPath = currentPath.isEmpty ? name : "\(currentPath)/\(name)"
        currentPath = newPath
        await loadCurrent()
    }
    
    private func navigateUp() async {
        let components = currentPath.split(separator: "/")
        currentPath = components.dropLast().joined(separator: "/")
        await loadCurrent()
    }
    
    private func createDirectory() async {
        // Simple implementation - could add text field
    }
}

/// Settings view
struct SettingsView: View {
    @Binding var config: Configuration
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Modelo") {
                    Picker("Proveedor", selection: $config.defaultModelProvider) {
                        Text("Remote API").tag("remote" as String?)
                        Text("CoreML (próximamente)").tag("coreml" as String?)
                    }
                    
                    TextField("Modelo", text: Binding(
                        get: { config.defaultModelName ?? "" },
                        set: { config.defaultModelName = $0.isEmpty ? nil : $0 }
                    ))
                }
                
                Section("Apariencia") {
                    Picker("Tema", selection: $config.theme) {
                        Text("Sistema").tag("system")
                        Text("Claro").tag("light")
                        Text("Oscuro").tag("dark")
                    }
                    
                    Slider(value: $config.fontSize, in: 10...24, step: 1) {
                        Text("Tamaño fuente: \(Int(config.fontSize))")
                    }
                }
                
                Section("Workspace") {
                    TextField("Ruta workspace", text: Binding(
                        get: { config.workspacePath ?? "" },
                        set: { config.workspacePath = $0.isEmpty ? nil : $0 }
                    ))
                }
                
                Section("Privacidad") {
                    Toggle("Auto-guardar", isOn: $config.autoSave)
                }
            }
            .navigationTitle("Configuración")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }
}

/// Capabilities view - muestra qué es posible en iOS
struct CapabilitiesView: View {
    @Environment(\.dismiss) var dismiss
    
    let capabilities: [(name: String, status: String, description: String, restriction: String?)] = [
        ("Leer archivos", "✅ Posible", "FileManager + sandbox", "Solo App Support/Documents/tmp"),
        ("Escribir archivos", "✅ Posible", "FileManager.write", "Solo directorios escribibles"),
        ("Listar directorios", "✅ Posible", "contentsOfDirectory", "Solo sandbox"),
        ("Crear directorios", "✅ Posible", "createDirectory", "Solo sandbox"),
        ("Mover/borrar archivos", "✅ Posible", "moveItem/removeItem", "Solo sandbox"),
        ("Buscar archivos", "✅ Posible", "Implementado en Swift", "Glob patterns, sin regex"),
        ("File watching", "⚠️ Limitado", "DispatchSource", "Solo directorios propios, no recursivo profundo"),
        ("Security bookmarks", "⚠️ Posible", "URL.bookmarkData", "Requiere picker + entitlement"),
        ("Ejecutar procesos", "❌ Imposible", "Sin Process/NSTask", "Sandbox prohíbe fork/exec"),
        ("Shell/bash", "❌ Imposible", "No hay terminal", "Fundamental de iOS"),
        ("Git", "❌ Imposible", "Sin libgit2 nativo", "Requiere compilar o backend"),
        ("Python/Node", "❌ Imposible", "No hay binarios", "Solo JS en WKWebView"),
        ("Compilar código", "❌ Imposible", "Sin toolchain", "Requiere backend externo"),
        ("Model API remoto", "✅ Posible", "URLSession async/await", "Red, latencia, API keys"),
        ("Model CoreML", "✅ Posible", "CoreML + .mlpackage", "Modelos <2GB, solo inference"),
        ("Persistencia JSON", "✅ Posible", "JSONEncoder + App Support", "Ilimitado hasta storage"),
        ("Persistencia SQLite", "✅ Posible", "SQLite.swift/CoreData", "Requiere librería"),
        ("Red localhost", "✅ Posible", "NWListener", "Solo 127.0.0.1, NSAllowsLocalNetworking"),
        ("Red externa", "✅ Posible", "URLSession", "ATS, certificados"),
        ("WKWebView JS", "✅ Posible", "WebKit", "Solo JS/WASM, sin filesystem directo"),
        ("Code signing", "❌ Windows", "Requiere macOS", "GitHub Actions + SideStore"),
    ]
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(capabilities, id: \.name) { cap in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cap.status)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(statusColor(cap.status).opacity(0.2))
                                .foregroundStyle(statusColor(cap.status))
                                .clipShape(Capsule())
                            Text(cap.name)
                                .font(.body.weight(.medium))
                        }
                        Text(cap.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let restriction = cap.restriction {
                            Text("Restricción: \(restriction)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Capabilities iOS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }
    
    private func statusColor(_ status: String) -> Color {
        if status.hasPrefix("✅") { return .green }
        if status.hasPrefix("⚠️") { return .orange }
        return .red
    }
}

// MARK: - Extensions

extension Message.Role {
    var displayName: String {
        switch self {
        case .user: return "Usuario"
        case .assistant: return "Asistente"
        case .system: return "Sistema"
        case .tool: return "Herramienta"
        }
    }
    
    var icon: String {
        switch self {
        case .user: return "person.fill"
        case .assistant: return "cpu.fill"
        case .system: return "gear"
        case .tool: return "wrench.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .user: return .blue
        case .assistant: return .purple
        case .system: return .gray
        case .tool: return .orange
        }
    }
}