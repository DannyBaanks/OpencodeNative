import Foundation

/// Capabilities que un proveedor de modelos declara.
public struct ModelProviderCapabilities: Codable, Sendable {
    public let streaming: Bool
    public let toolCalls: Bool
    public let maxTokens: Int?
    public let maxContextTokens: Int?
    public let supportsSystemPrompt: Bool
    public let supportsImages: Bool
    public let localOnly: Bool // true = runs on-device (CoreML), false = remote API
    
    public let restrictions: [String]
    
    public init(
        streaming: Bool = false,
        toolCalls: Bool = false,
        maxTokens: Int? = nil,
        maxContextTokens: Int? = nil,
        supportsSystemPrompt: Bool = true,
        supportsImages: Bool = false,
        localOnly: Bool = false,
        restrictions: [String] = []
    ) {
        self.streaming = streaming
        self.toolCalls = toolCalls
        self.maxTokens = maxTokens
        self.maxContextTokens = maxContextTokens
        self.supportsSystemPrompt = supportsSystemPrompt
        self.supportsImages = supportsImages
        self.localOnly = localOnly
        self.restrictions = restrictions
    }
}

/// Respuesta de un modelo
public struct ModelResponse: Codable, Sendable {
    public let content: String
    public let toolCalls: [ToolCall]?
    public let usage: Usage?
    public let finishReason: String?
    public let metadata: [String: String]
    
    public struct Usage: Codable, Sendable {
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int
    }
    
    public init(
        content: String,
        toolCalls: [ToolCall]? = nil,
        usage: Usage? = nil,
        finishReason: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.usage = usage
        self.finishReason = finishReason
        self.metadata = metadata
    }
}

/// Chunk de streaming
public struct ModelStreamChunk: Codable, Sendable {
    public let delta: String?
    public let toolCallDelta: ToolCallDelta?
    public let done: Bool
    public let finishReason: String?
    
    public struct ToolCallDelta: Codable, Sendable {
        public let index: Int
        public let name: String?
        public let arguments: String?
    }
}

/// Errores del proveedor
public enum ModelProviderError: Error, LocalizedError, Sendable {
    case notConfigured(String)
    case networkError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case contextTooLarge(maxTokens: Int)
    case invalidRequest(String)
    case modelNotFound(String)
    case authenticationFailed
    case unsupportedFeature(String)
    
    public var errorDescription: String? {
        switch self {
        case .notConfigured(let m): return "Provider not configured: \(m)"
        case .networkError(let m): return "Network error: \(m)"
        case .rateLimited(let retry): return "Rate limited" + (retry.map { ", retry after \($0)s" } ?? "")
        case .contextTooLarge(let max): return "Context too large, max \(max) tokens"
        case .invalidRequest(let m): return "Invalid request: \(m)"
        case .modelNotFound(let m): return "Model not found: \(m)"
        case .authenticationFailed: return "Authentication failed"
        case .unsupportedFeature(let m): return "Unsupported feature: \(m)"
        }
    }
}

/// Protocolo para proveedores de modelos.
/// Abstracción que permite swapping entre remoto (API) y local (CoreML).
public protocol ModelProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var capabilities: ModelProviderCapabilities { get }
    var availableModels: [String] { get }
    
    func configure(_ config: ModelConfiguration) async throws
    func generate(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) async throws -> ModelResponse
    
    func generateStream(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelStreamChunk, Error>
}

/// Mensaje para el modelo
public struct ModelMessage: Codable, Sendable {
    public let role: Role
    public let content: String
    public let name: String? // for tool messages
    public let toolCallId: String? // for tool results
    public let metadata: [String: String]
    
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }
    
    public init(role: Role, content: String, name: String? = nil, toolCallId: String? = nil, metadata: [String: String] = [:]) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallId = toolCallId
        self.metadata = metadata
    }
}

/// Definición de herramienta (OpenAI function calling style)
public struct ToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let parameters: ToolParameters
    
    public struct ToolParameters: Codable, Sendable {
        public let type: String = "object"
        public let properties: [String: PropertySchema]
        public let required: [String]
    }
    
    public struct PropertySchema: Codable, Sendable {
        public let type: String
        public let description: String?
        public let enumValues: [String]?
    }
}

/// Opciones de generación
public struct GenerationOptions: Codable, Sendable {
    public let model: String?
    public let temperature: Double?
    public let maxTokens: Int?
    public let topP: Double?
    public let stopSequences: [String]?
    public let seed: Int?
    
    public init(
        model: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        stopSequences: [String]? = nil,
        seed: Int? = nil
    ) {
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.stopSequences = stopSequences
        self.seed = seed
    }
}

/// Configuración del proveedor
public struct ModelConfiguration: Codable, Sendable {
    public let apiKey: String?
    public let baseURL: String?
    public let organization: String?
    public let timeout: TimeInterval
    public let extraHeaders: [String: String]
    
    public init(
        apiKey: String? = nil,
        baseURL: String? = nil,
        organization: String? = nil,
        timeout: TimeInterval = 60,
        extraHeaders: [String: String] = [:]
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.organization = organization
        self.timeout = timeout
        self.extraHeaders = extraHeaders
    }
}

/// Proveedor remoto genérico (OpenAI-compatible API)
/// Compatible con OpenAI, Anthropic (via proxy), Ollama, vLLM, etc.
public actor RemoteModelProvider: ModelProvider {
    public let id: String
    public let name: String
    public let capabilities: ModelProviderCapabilities
    public private(set) var availableModels: [String] = []
    
    private var config: ModelConfiguration?
    private let session: URLSession
    
    public init(id: String = "remote", name: String = "Remote API") {
        self.id = id
        self.name = name
        self.capabilities = ModelProviderCapabilities(
            streaming: true,
            toolCalls: true,
            maxTokens: 4096,
            maxContextTokens: 128000,
            supportsSystemPrompt: true,
            supportsImages: false,
            localOnly: false,
            restrictions: [
                "Requires network connectivity",
                "API key required",
                "Latency depends on network",
                "Cost per token",
                "Rate limits apply"
            ]
        )
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }
    
    public func configure(_ config: ModelConfiguration) async throws {
        self.config = config
        // Try to fetch available models
        try await fetchModels()
    }
    
    private func fetchModels() async throws {
        guard let config = config, let baseURL = config.baseURL else { return }
        guard let url = URL(string: baseURL + "/models") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, _) = try await session.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArray = json["data"] as? [[String: Any]] {
                self.availableModels = dataArray.compactMap { $0["id"] as? String }
            }
        } catch {
            // Models list is optional, continue with defaults
            self.availableModels = ["gpt-3.5-turbo", "gpt-4", "gpt-4-turbo"]
        }
    }
    
    public func generate(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) async throws -> ModelResponse {
        guard let config = config else {
            throw ModelProviderError.notConfigured("Call configure() first")
        }
        
        let request = try buildRequest(messages: messages, tools: tools, options: options, stream: false)
        let (data, response) = try await session.data(for: request)
        
        try checkResponse(response)
        return try parseResponse(data)
    }
    
    public func generateStream(
        messages: [ModelMessage],
        tools: [ToolDefinition]?,
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let config = config else {
                        throw ModelProviderError.notConfigured("Call configure() first")
                    }
                    
                    let request = try buildRequest(messages: messages, tools: tools, options: options, stream: true)
                    let (bytes, response) = try await session.bytes(for: request)
                    
                    try checkResponse(response)
                    
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6))
                            if jsonStr == "[DONE]" {
                                continuation.yield(ModelStreamChunk(delta: nil, toolCallDelta: nil, done: true, finishReason: "stop"))
                                break
                            }
                            if let chunk = try? JSONDecoder().decode(StreamChunkResponse.self, from: Data(jsonStr.utf8)) {
                                if let choice = chunk.choices.first {
                                    let delta = choice.delta.content
                                    let toolCallDelta = choice.delta.toolCalls?.first.map { tc in
                                        ModelStreamChunk.ToolCallDelta(index: tc.index, name: tc.function?.name, arguments: tc.function?.arguments)
                                    }
                                    continuation.yield(ModelStreamChunk(
                                        delta: delta,
                                        toolCallDelta: toolCallDelta,
                                        done: false,
                                        finishReason: choice.finishReason
                                    ))
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private func buildRequest(messages: [ModelMessage], tools: [ToolDefinition]?, options: GenerationOptions, stream: Bool) throws -> URLRequest {
        guard let config = config, let baseURL = config.baseURL, let url = URL(string: baseURL + "/chat/completions") else {
            throw ModelProviderError.invalidRequest("Invalid base URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        config.extraHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        
        var body: [String: Any] = [
            "model": options.model ?? availableModels.first ?? "gpt-3.5-turbo",
            "messages": messages.map { msg in
                var m: [String: Any] = ["role": msg.role.rawValue, "content": msg.content]
                if let name = msg.name { m["name"] = name }
                if let toolCallId = msg.toolCallId { m["tool_call_id"] = toolCallId }
                return m
            },
            "stream": stream
        ]
        
        if let temp = options.temperature { body["temperature"] = temp }
        if let maxTokens = options.maxTokens { body["max_tokens"] = maxTokens }
        if let topP = options.topP { body["top_p"] = topP }
        if let stop = options.stopSequences { body["stop"] = stop }
        if let seed = options.seed { body["seed"] = seed }
        
        if let tools = tools {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": [
                            "type": tool.parameters.type,
                            "properties": tool.parameters.properties.mapValues { prop in
                                var p: [String: Any] = ["type": prop.type]
                                if let desc = prop.description { p["description"] = desc }
                                if let enumV = prop.enumValues { p["enum"] = enumV }
                                return p
                            },
                            "required": tool.parameters.required
                        ]
                    ]
                ]
            }
            body["tool_choice"] = "auto"
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    
    private func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw ModelProviderError.authenticationFailed
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ModelProviderError.rateLimited(retryAfter: retry)
        case 400..<500: throw ModelProviderError.invalidRequest("HTTP \(http.statusCode)")
        default: throw ModelProviderError.networkError("HTTP \(http.statusCode)")
        }
    }
    
    private func parseResponse(_ data: Data) throws -> ModelResponse {
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw ModelProviderError.invalidRequest("No choices in response")
        }
        
        let toolCalls = choice.message.toolCalls?.map { tc in
            ToolCall(id: tc.id, name: tc.function.name, arguments: tc.function.arguments)
        }
        
        let usage = decoded.usage.map { u in
            ModelResponse.Usage(promptTokens: u.promptTokens, completionTokens: u.completionTokens, totalTokens: u.totalTokens)
        }
        
        return ModelResponse(
            content: choice.message.content ?? "",
            toolCalls: toolCalls,
            usage: usage,
            finishReason: choice.finishReason,
            metadata: [:]
        )
    }
}

// MARK: - Response decoding

private struct ChatCompletionResponse: Codable {
    let choices: [Choice]
    let usage: Usage?
    
    struct Choice: Codable {
        let message: Message
        let finishReason: String?
        
        struct Message: Codable {
            let content: String?
            let toolCalls: [ToolCallResponse]?
        }
        
        struct ToolCallResponse: Codable {
            let id: String
            let function: Function
            
            struct Function: Codable {
                let name: String
                let arguments: String
            }
        }
    }
    
    struct Usage: Codable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
    }
}

private struct StreamChunkResponse: Codable {
    let choices: [StreamChoice]
    
    struct StreamChoice: Codable {
        let delta: Delta
        let finishReason: String?
        
        struct Delta: Codable {
            let content: String?
            let toolCalls: [StreamToolCall]?
        }
        
        struct StreamToolCall: Codable {
            let index: Int
            let function: StreamFunction?
            
            struct StreamFunction: Codable {
                let name: String?
                let arguments: String?
            }
        }
    }
}