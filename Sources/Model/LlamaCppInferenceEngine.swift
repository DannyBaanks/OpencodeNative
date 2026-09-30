import Foundation

protocol LocalInferenceEngine: Sendable {
    func load(modelURL: URL, contextTokens: Int) async throws
    func generate(messages: [ModelMessage], options: GenerationOptions) async throws -> String
    func cancel() async
    func unload() async
}

final class LlamaCppInferenceEngine: LocalInferenceEngine, @unchecked Sendable {
    private let lock = NSLock()
    // A llama_context is mutable; serialize load and decoding across sessions.
    private let inferenceLane = DispatchSemaphore(value: 1)
    private var context: OpaquePointer?
    /// Builtin llama.cpp template name from the catalog; nil uses the GGUF's own.
    private let chatTemplateOverride: String?

    public init(chatTemplateOverride: String? = nil) {
        self.chatTemplateOverride = chatTemplateOverride
    }

    deinit {
        lock.lock()
        let current = context
        context = nil
        lock.unlock()
        if let current { gus_llama_destroy(current) }
    }

    public func load(modelURL: URL, contextTokens: Int) async throws {
        guard contextTokens == 2048 || contextTokens == 4096 else {
            throw ModelProviderError.unsupportedFeature("GUS solo ofrece perfiles de 2K y 4K experimental.")
        }
        let path = modelURL.path
        let loaded = await Task.detached(priority: .userInitiated) { [self] in
            inferenceLane.wait()
            defer { inferenceLane.signal() }
            lock.lock()
            let alreadyLoaded = context != nil
            lock.unlock()
            guard !alreadyLoaded else { return true }
            var error = [CChar](repeating: 0, count: 512)
            let created = path.withCString { cPath in
                error.withUnsafeMutableBufferPointer { buffer in
                    gus_llama_create(cPath, UInt32(contextTokens), buffer.baseAddress, buffer.count)
                }
            }
            guard let created else { return false }
            lock.lock()
            context = created
            lock.unlock()
            return true
        }.value
        guard loaded else {
            throw ModelProviderError.invalidRequest("No pude cargar el modelo local. Comprueba almacenamiento y memoria disponibles.")
        }
    }

    public func generate(messages: [ModelMessage], options: GenerationOptions) async throws -> String {
        try await generateMeasured(messages: messages, options: options).text
    }

    /// Generates with the model's own chat template and reports timing, used by
    /// the on-device benchmark. Message contents are never logged.
    func generateMeasured(messages: [ModelMessage], options: GenerationOptions) async throws -> LocalGeneration {
        let chat = Self.chatMessages(messages)
        let maxTokens = min(max(options.maxTokens ?? 256, 1), 256)
        let templateOverride = chatTemplateOverride
        let result: Result<LocalGeneration, LocalGenerationFailure> = await Task.detached(priority: .userInitiated) { [self] in
            inferenceLane.wait()
            defer { inferenceLane.signal() }
            lock.lock()
            let current = context
            lock.unlock()
            guard let current else {
                return .failure(LocalGenerationFailure(message: "El modelo GUS local no está cargado."))
            }
            // C strings must outlive the call; strdup keeps each one stable.
            let cStrings = chat.flatMap { [strdup($0.role), strdup($0.content)] }
            defer { cStrings.forEach { free($0) } }
            guard !cStrings.contains(where: { $0 == nil }) else {
                return .failure(LocalGenerationFailure(message: "Not enough memory to prepare the prompt."))
            }
            var cMessages = stride(from: 0, to: cStrings.count, by: 2).map { index in
                GUSChatMessage(role: UnsafePointer(cStrings[index]), content: UnsafePointer(cStrings[index + 1]))
            }
            var stats = GUSGenerationStats()
            var error = [CChar](repeating: 0, count: 512)
            let text: UnsafeMutablePointer<CChar>? = cMessages.withUnsafeMutableBufferPointer { messagesBuffer in
                error.withUnsafeMutableBufferPointer { errorBuffer in
                    if let templateOverride {
                        return templateOverride.withCString { cTemplate in
                            gus_llama_generate_chat(current, messagesBuffer.baseAddress, messagesBuffer.count, cTemplate,
                                                    UInt32(maxTokens), &stats, errorBuffer.baseAddress, errorBuffer.count)
                        }
                    }
                    return gus_llama_generate_chat(current, messagesBuffer.baseAddress, messagesBuffer.count, nil,
                                                   UInt32(maxTokens), &stats, errorBuffer.baseAddress, errorBuffer.count)
                }
            }
            guard let text else {
                let message = error.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress.map { String(cString: $0) } ?? "Local inference failed."
                }
                return .failure(LocalGenerationFailure(message: message))
            }
            defer { gus_llama_free_text(text) }
            return .success(LocalGeneration(text: Self.visibleAnswer(String(cString: text)), stats: LocalGenerationStats(stats)))
        }.value
        switch result {
        case .success(let generation): return generation
        case .failure(let failure):
            if failure.message.localizedCaseInsensitiveContains("cancel") { throw CancellationError() }
            throw ModelProviderError.invalidRequest(failure.message)
        }
    }

    /// Short description of the loaded model (architecture, parameters, size).
    func modelDescription() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let context, let text = gus_llama_model_description(context) else { return nil }
        defer { gus_llama_free_text(text) }
        return String(cString: text)
    }

    public func cancel() async {
        lock.lock()
        let current = context
        if let current { gus_llama_cancel(current) }
        lock.unlock()
    }

    public func unload() async {
        await Task.detached(priority: .utility) { [self] in
            inferenceLane.wait()
            defer { inferenceLane.signal() }
            lock.lock()
            let current = context
            context = nil
            lock.unlock()
            if let current { gus_llama_destroy(current) }
        }.value
    }

    /// Maps app roles onto chat-template roles. Framing is applied in C with the
    /// model's own template; control-token spellings inside content are
    /// neutralized there, for every vocabulary rather than only ChatML.
    static func chatMessages(_ messages: [ModelMessage]) -> [(role: String, content: String)] {
        messages.map { message in
            switch message.role {
            case .system: return ("system", message.content)
            case .user, .tool: return ("user", message.content)
            case .assistant: return ("assistant", message.content)
            }
        }
    }

    /// Reasoning models (Qwen3, SmolLM3, Nemotron) may emit a think block first;
    /// only the answer is shown. An unterminated block means the budget ran out.
    static func visibleAnswer(_ raw: String) -> String {
        guard let open = raw.range(of: "<think>") else { return raw }
        guard let close = raw.range(of: "</think>", range: open.upperBound..<raw.endIndex) else {
            return String(raw[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let answer = String(raw[..<open.lowerBound]) + String(raw[close.upperBound...])
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LocalGeneration: Sendable {
    let text: String
    let stats: LocalGenerationStats
}

struct LocalGenerationStats: Sendable, Equatable, Codable {
    enum TemplateSource: String, Sendable, Codable { case override, embedded, fallbackChatML }
    let promptTokens: Int
    let generatedTokens: Int
    let prefillMilliseconds: Double
    let generateMilliseconds: Double
    let templateSource: TemplateSource
    let stoppedAtEndOfTurn: Bool

    var prefillTokensPerSecond: Double { prefillMilliseconds > 0 ? Double(promptTokens) * 1000 / prefillMilliseconds : 0 }
    var generationTokensPerSecond: Double { generateMilliseconds > 0 ? Double(generatedTokens) * 1000 / generateMilliseconds : 0 }

    init(promptTokens: Int, generatedTokens: Int, prefillMilliseconds: Double, generateMilliseconds: Double,
         templateSource: TemplateSource, stoppedAtEndOfTurn: Bool) {
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.prefillMilliseconds = prefillMilliseconds
        self.generateMilliseconds = generateMilliseconds
        self.templateSource = templateSource
        self.stoppedAtEndOfTurn = stoppedAtEndOfTurn
    }

    init(_ raw: GUSGenerationStats) {
        let source: TemplateSource
        switch raw.template_source {
        case 0: source = .override
        case 1: source = .embedded
        default: source = .fallbackChatML
        }
        self.init(promptTokens: Int(raw.prompt_tokens), generatedTokens: Int(raw.generated_tokens),
                  prefillMilliseconds: raw.prefill_ms, generateMilliseconds: raw.generate_ms,
                  templateSource: source, stoppedAtEndOfTurn: raw.stopped_at_eog != 0)
    }
}

private struct LocalGenerationFailure: Error, Sendable {
    let message: String
}
