import Foundation
import SwiftUI

/// ViewModel principal que conecta UI con el runtime del agente
@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public var messages: [Message] = []
    @Published public var inputText: String = ""
    @Published public var isProcessing: Bool = false
    @Published public var errorMessage: String?
    @Published public var workspacePath: String = ""
    @Published public var showWorkspacePicker: Bool = false
    @Published public var showSettings: Bool = false
    @Published public var showCapabilities: Bool = false
    @Published public var config: Configuration = Configuration()
    
    // Componentes del runtime
    private var workspace: IOSWorkspace?
    private var persistence: IOSPersistence?
    private var modelProvider: RemoteModelProvider?
    private var toolExecutor: FileSystemToolExecutor?
    private var agentLoop: AgentLoop?
    private var conversationId: String = UUID().uuidString
    
    public init() {}
    
    public func initialize() async {
        do {
            // Inicializar componentes
            self.workspace = try IOSWorkspace()
            self.persistence = try IOSPersistence()
            self.modelProvider = RemoteModelProvider()
            self.toolExecutor = FileSystemToolExecutor(workspace: workspace!)
            
            // Cargar configuración guardada
            if let savedConfig = try await persistence?.loadConfiguration() {
                self.config = savedConfig
            }
            
            // Configurar proveedor de modelo si hay API key
            if let provider = modelProvider {
                let modelConfig = ModelConfiguration(
                    apiKey: config.apiKeys[config.defaultModelProvider ?? "remote"],
                    baseURL: "https://api.openai.com/v1" // Default, configurable
                )
                try await provider.configure(modelConfig)
            }
            
            // Configurar executor de herramientas
            if let toolExecutor = toolExecutor {
                // Tools ya están definidas en el executor
            }
            
            // Crear agent loop
            if let workspace = workspace,
               let persistence = persistence,
               let modelProvider = modelProvider,
               let toolExecutor = toolExecutor {
                
                let context = AgentContext(
                    conversationId: conversationId,
                    workspace: workspace,
                    persistence: persistence,
                    modelProvider: modelProvider,
                    toolExecutor: toolExecutor,
                    systemPrompt: buildSystemPrompt(),
                    maxTurns: 10
                )
                
                self.agentLoop = AgentLoop(context: context)
                
                self.agentLoop?.setEventHandler { [weak self] event in
                    Task { @MainActor in
                        self?.handleAgentEvent(event)
                    }
                }
            }
            
            // Cargar conversación existente o crear nueva
            await loadOrCreateConversation()
            
        } catch {
            self.errorMessage = "Error inicializando: \(error.localizedDescription)"
        }
    }
    
    private func buildSystemPrompt() -> String {
        """
        Eres un asistente de código que opera NATIVAMENTE en iOS.
        
        CAPACIDADES DISPONIBLES:
        - Leer/escribir/listar archivos en el workspace (sandbox iOS)
        - Buscar archivos con patrones glob
        - Crear/borrar/mover archivos y directorios
        - Obtener metadata de archivos
        
        RESTRICCIONES IMPORTANTES:
        - NO puedes ejecutar comandos de shell (bash, python, git, etc.)
        - NO puedes compilar código (sin toolchain en iOS)
        - NO tienes acceso fuera del sandbox de la app
        - El workspace está en Application Support/OpencodeNative/workspace/
        - Solo herramientas declaradas explícitamente están disponibles
        
        Cuando el usuario pida algo que requiera capacidades no disponibles,
        explica la limitación y ofrece alternativas dentro de lo posible.
        
        Responde de forma concisa y técnica.
        """
    }
    
    public func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isProcessing, let agentLoop = agentLoop else { return }
        
        inputText = ""
        isProcessing = true
        errorMessage = nil
        
        Task {
            do {
                let response = try await agentLoop.run(userInput: text)
                await MainActor.run {
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    public func newConversation() {
        conversationId = UUID().uuidString
        messages = []
        agentLoop = nil
        Task {
            await initialize()
        }
    }
    
    private func loadOrCreateConversation() async {
        guard let persistence = persistence else { return }
        
        if let existing = try? await persistence.loadConversation(id: conversationId) {
            // Convertir mensajes existentes
            self.messages = existing.messages
        }
    }
    
    private func handleAgentEvent(_ event: AgentLoopEvent) {
        switch event {
        case .modelResponse(let response):
            if !response.content.isEmpty {
                messages.append(Message(role: .assistant, content: response.content))
            }
            
        case .toolResult(let result):
            // El mensaje del asistente ya se añadió con toolCalls
            // Los resultados se añaden como mensajes de herramienta
            if let lastIndex = messages.lastIndex(where: { $0.role == .assistant }) {
                var lastMsg = messages[lastIndex]
                var results = lastMsg.toolResults ?? []
                results.append(ToolResult(
                    toolCallId: result.toolCallId,
                    output: result.output,
                    error: result.error
                ))
                lastMsg = Message(
                    id: lastMsg.id,
                    role: lastMsg.role,
                    content: lastMsg.content,
                    toolCalls: lastMsg.toolCalls,
                    toolResults: results,
                    timestamp: lastMsg.timestamp,
                    metadata: lastMsg.metadata
                )
                messages[lastIndex] = lastMsg
            }
            
        case .error(let error):
            errorMessage = error.localizedDescription
            
        case .finished(let finalResponse):
            if !finalResponse.isEmpty && !messages.contains(where: { $0.content == finalResponse && $0.role == .assistant }) {
                messages.append(Message(role: .assistant, content: finalResponse))
            }
            
        default:
            break
        }
    }
}