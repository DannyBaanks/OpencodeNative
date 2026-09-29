import Foundation

/// First release is local guidance only. Qwen 1.5 tool-call output has not yet
/// been validated, so it is never parsed into executable NativeCapabilities.
public struct GUSLocalModelProvider: ModelProvider {
    public let id = "gus-local"
    public var name: String { "GUS local · \(manifest.modelName)" }
    public let capabilities = ModelProviderCapabilities(
        streaming: false,
        toolCalls: false,
        maxTokens: 256,
        maxContextTokens: 2048,
        supportsSystemPrompt: true,
        supportsImages: false,
        localOnly: true,
        restrictions: ["Inferencia local solamente", "Guía solamente hasta validar las llamadas a herramientas Qwen 1.5"]
    )
    public var availableModels: [String] { [manifest.id] }

    private let engine: any LocalInferenceEngine
    private let modelURL: URL
    public let manifest: GUSModelManifest

    // Internal so callers outside the app's verified download path cannot hand
    // an arbitrary file URL to the local runtime.
    init(modelURL: URL, manifest: GUSModelManifest = .qwen15Q4KM, engine: any LocalInferenceEngine = LlamaCppInferenceEngine()) {
        self.modelURL = modelURL
        self.manifest = manifest
        self.engine = engine
    }

    public func load(contextTokens: Int = 2048) async throws {
        try await engine.load(modelURL: modelURL, contextTokens: contextTokens)
    }

    public func configure(_ config: ModelConfiguration) async throws {
        guard config.apiKey == nil || config.apiKey?.isEmpty == true else {
            throw ModelProviderError.invalidRequest("GUS local no acepta ni almacena API keys.")
        }
    }

    public func generate(messages: [ModelMessage], tools: [ToolDefinition]?, options: GenerationOptions) async throws -> ModelResponse {
        var localMessages = messages
        let localBoundary = "Esta versión local es solo de orientación: no puede ejecutar herramientas ni cambiar archivos. Explica el límite y ofrece pasos que el usuario pueda revisar."
        if let systemIndex = localMessages.firstIndex(where: { $0.role == .system }) {
            let original = localMessages[systemIndex]
            localMessages[systemIndex] = ModelMessage(role: .system, content: original.content + "\n\n" + localBoundary)
        } else {
            localMessages.insert(ModelMessage(role: .system, content: localBoundary), at: 0)
        }
        let text = try await engine.generate(messages: localMessages, options: options)
        return ModelResponse(content: text, toolCalls: nil, finishReason: "stop", metadata: ["execution": "on-device", "model": manifest.modelName, "model_id": manifest.id])
    }

    public func generateStream(messages: [ModelMessage], tools: [ToolDefinition]?, options: GenerationOptions) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await generate(messages: messages, tools: tools, options: options)
                    continuation.yield(ModelStreamChunk(delta: response.content, toolCallDelta: nil, done: true, finishReason: "stop"))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    public func cancel() async { await engine.cancel() }
}
