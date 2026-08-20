import Foundation

/// Definición de una herramienta disponible para el agente
public struct AgentTool: Sendable, Codable {
    public let name: String
    public let description: String
    public let parameters: ToolSchema
    public let capabilities: ToolCapabilities
    
    public struct ToolSchema: Codable, Sendable {
        public let type: String = "object"
        public let properties: [String: PropertySchema]
        public let required: [String]
    }
    
    public struct PropertySchema: Codable, Sendable {
        public let type: String
        public let description: String?
        public let enumValues: [String]?
    }
    
    public struct ToolCapabilities: Codable, Sendable {
        public let requiresNetwork: Bool = false
        public let requiresFileSystem: Bool = false
        public let isDestructive: Bool = false
        public let restrictions: [String] = []
    }
    
    public init(
        name: String,
        description: String,
        properties: [String: PropertySchema],
        required: [String] = [],
        capabilities: ToolCapabilities = ToolCapabilities()
    ) {
        self.name = name
        self.description = description
        self.parameters = ToolSchema(properties: properties, required: required)
        self.capabilities = capabilities
    }
}

/// Llamada a herramienta desde el modelo
public struct ToolInvocation: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: [String: String]
    public let timestamp: Date
    
    public init(id: String = UUID().uuidString, name: String, arguments: [String: String]) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.timestamp = Date()
    }
}

/// Resultado de ejecución de herramienta
public struct ToolExecutionResult: Codable, Sendable, Identifiable {
    public let id: String
    public let toolCallId: String
    public let output: String
    public let error: String?
    public let duration: TimeInterval
    public let timestamp: Date
    
    public init(
        id: String = UUID().uuidString,
        toolCallId: String,
        output: String,
        error: String? = nil,
        duration: TimeInterval
    ) {
        self.id = id
        self.toolCallId = toolCallId
        self.output = output
        self.error = error
        self.duration = duration
        self.timestamp = Date()
    }
}

/// Protocolo para ejecutor de herramientas
public protocol ToolExecutor: Sendable {
    var availableTools: [AgentTool] { get }
    func execute(_ invocation: ToolInvocation) async -> ToolExecutionResult
}

/// Contexto de ejecución del agente
public struct AgentContext: Sendable {
    public let conversationId: String
    public let workspace: any Workspace
    public let persistence: any Persistence
    public let modelProvider: any ModelProvider
    public let toolExecutor: any ToolExecutor
    public let systemPrompt: String?
    public let maxTurns: Int
    
    public init(
        conversationId: String,
        workspace: any Workspace,
        persistence: any Persistence,
        modelProvider: any ModelProvider,
        toolExecutor: any ToolExecutor,
        systemPrompt: String? = nil,
        maxTurns: Int = 10
    ) {
        self.conversationId = conversationId
        self.workspace = workspace
        self.persistence = persistence
        self.modelProvider = modelProvider
        self.toolExecutor = toolExecutor
        self.systemPrompt = systemPrompt
        self.maxTurns = maxTurns
    }
}

/// Eventos del loop del agente (para observabilidad)
public enum AgentLoopEvent: Sendable {
    case turnStarted(turn: Int)
    case modelRequest(messages: [ModelMessage])
    case modelResponse(ModelResponse)
    case toolInvocation(ToolInvocation)
    case toolResult(ToolExecutionResult)
    case turnCompleted
    case error(Error)
    case finished(finalResponse: String)
}

/// Loop principal del agente
/// Ejecuta: user input → model → tool calls → results → model → response
public actor AgentLoop {
    private let context: AgentContext
    private var turnCount = 0
    private var currentConversation: Conversation?
    private var eventHandler: (@Sendable (AgentLoopEvent) async -> Void)?
    
    public init(context: AgentContext) {
        self.context = context
    }
    
    public func setEventHandler(_ handler: @escaping @Sendable (AgentLoopEvent) async -> Void) {
        self.eventHandler = handler
    }
    
    /// Ejecuta un turno completo del agente
    /// Retorna la respuesta final del asistente
    public func run(userInput: String) async throws -> String {
        // Cargar o crear conversación
        if currentConversation == nil {
            if let existing = try await context.persistence.loadConversation(id: context.conversationId) {
                currentConversation = existing
            } else {
                currentConversation = Conversation(id: context.conversationId)
            }
        }
        
        guard var conversation = currentConversation else {
            throw AgentError.noConversation
        }
        
        // Añadir mensaje del usuario
        let userMessage = Message(role: .user, content: userInput)
        conversation.messages.append(userMessage)
        try await context.persistence.saveConversation(conversation)
        try await context.persistence.appendEvent(AgentEvent(conversationId: context.conversationId, type: .userInput, payload: ["content": userInput]))
        
        // Loop de turnos
        var finalResponse = ""
        
        for turn in 1...context.maxTurns {
            turnCount = turn
            await eventHandler?(.turnStarted(turn: turn))
            
            // Construir mensajes para el modelo
            let modelMessages = buildModelMessages(from: conversation)
            
            await eventHandler?(.modelRequest(messages: modelMessages))
            
            // Llamar al modelo
            let tools = context.toolExecutor.availableTools.map { tool in
                ToolDefinition(
                    name: tool.name,
                    description: tool.description,
                    parameters: ToolDefinition.ToolParameters(
                        properties: tool.parameters.properties,
                        required: tool.parameters.required
                    )
                )
            }
            
            let options = GenerationOptions(
                temperature: 0.7,
                maxTokens: 2048
            )
            
            let response = try await context.modelProvider.generate(
                messages: modelMessages,
                tools: tools.isEmpty ? nil : tools,
                options: options
            )
            
            await eventHandler?(.modelResponse(response))
            
            // Añadir respuesta del modelo a la conversación
            var assistantMessage = Message(role: .assistant, content: response.content)
            
            // Si hay tool calls, ejecutarlos
            if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                assistantMessage = Message(
                    role: .assistant,
                    content: response.content,
                    toolCalls: toolCalls
                )
                conversation.messages.append(assistantMessage)
                
                // Ejecutar cada tool call
                for toolCall in toolCalls {
                    let invocation = ToolInvocation(name: toolCall.name, arguments: toolCall.arguments)
                    await eventHandler?(.toolInvocation(invocation))
                    
                    let startTime = Date()
                    let result = await context.toolExecutor.execute(invocation)
                    
                    await eventHandler?(.toolResult(result))
                    
                    // Añadir resultado a la conversación
                    let toolResultMsg = Message(
                        role: .tool,
                        content: result.output,
                        toolResults: [ToolResult(
                            toolCallId: invocation.id,
                            output: result.output,
                            error: result.error
                        )]
                    )
                    conversation.messages.append(toolResultMsg)
                    
                    try await context.persistence.appendEvent(AgentEvent(
                        conversationId: context.conversationId,
                        type: .toolResult,
                        payload: ["tool": invocation.name, "output": result.output, "error": result.error ?? ""]
                    ))
                }
                
                // Continuar el loop para que el modelo procese los resultados
                continue
            } else {
                // No hay tool calls, respuesta final
                finalResponse = response.content
                conversation.messages.append(Message(role: .assistant, content: finalResponse))
                break
            }
        }
        
        if finalResponse.isEmpty {
            finalResponse = "Max turns reached without final response"
        }
        
        // Guardar conversación actualizada
        try await context.persistence.saveConversation(conversation)
        try await context.persistence.appendEvent(AgentEvent(
            conversationId: context.conversationId,
            type: .modelResponse,
            payload: ["response": finalResponse]
        ))
        
        await eventHandler?(.finished(finalResponse: finalResponse))
        
        return finalResponse
    }
    
    private func buildModelMessages(from conversation: Conversation) -> [ModelMessage] {
        var messages: [ModelMessage] = []
        
        // System prompt
        if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
            messages.append(ModelMessage(role: .system, content: systemPrompt))
        }
        
        // Historial de conversación
        for msg in conversation.messages {
            switch msg.role {
            case .user:
                messages.append(ModelMessage(role: .user, content: msg.content))
            case .assistant:
                var content = msg.content
                if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    // El modelo ya incluyó los tool calls en su respuesta
                }
                messages.append(ModelMessage(role: .assistant, content: content))
            case .tool:
                if let toolResults = msg.toolResults {
                    for result in toolResults {
                        messages.append(ModelMessage(
                            role: .tool,
                            content: result.output,
                            toolCallId: result.toolCallId
                        ))
                    }
                }
            case .system:
                messages.append(ModelMessage(role: .system, content: msg.content))
            }
        }
        
        return messages
    }
}

/// Errores del agente
public enum AgentError: Error, LocalizedError, Sendable {
    case noConversation
    case maxTurnsExceeded
    case modelError(String)
    case toolError(String)
    case persistenceError(String)
    
    public var errorDescription: String? {
        switch self {
        case .noConversation: return "No active conversation"
        case .maxTurnsExceeded: return "Maximum turns exceeded"
        case .modelError(let m): return "Model error: \(m)"
        case .toolError(let m): return "Tool error: \(m)"
        case .persistenceError(let m): return "Persistence error: \(m)"
        }
    }
}