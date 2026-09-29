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

    public init() {}

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
        let prompt = Self.chatPrompt(messages)
        let maxTokens = min(max(options.maxTokens ?? 256, 1), 256)
        let result: Result<String, LocalGenerationFailure> = await Task.detached(priority: .userInitiated) { [self] in
            inferenceLane.wait()
            defer { inferenceLane.signal() }
            lock.lock()
            let current = context
            lock.unlock()
            guard let current else {
                return .failure(LocalGenerationFailure(message: "El modelo GUS local no está cargado."))
            }
            var error = [CChar](repeating: 0, count: 512)
            let text = prompt.withCString { cPrompt in
                error.withUnsafeMutableBufferPointer { buffer in
                    gus_llama_generate(current, cPrompt, UInt32(maxTokens), buffer.baseAddress, buffer.count)
                }
            }
            guard let text else {
                let message = error.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress.map { String(cString: $0) } ?? "Local inference failed."
                }
                return .failure(LocalGenerationFailure(message: message))
            }
            defer { gus_llama_free_text(text) }
            return .success(String(cString: text))
        }.value
        switch result {
        case .success(let text): return text
        case .failure(let failure):
            if failure.message.localizedCaseInsensitiveContains("cancel") { throw CancellationError() }
            throw ModelProviderError.invalidRequest(failure.message)
        }
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

    private static func chatPrompt(_ messages: [ModelMessage]) -> String {
        messages.map { message in
            let role: String
            switch message.role {
            case .system: role = "system"
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "user"
            }
            // Keep user/tool text from injecting llama.cpp control tokens into the chat framing.
            let safeContent = message.content.replacingOccurrences(of: "<|", with: "< |")
            return "<|im_start|>\(role)\n\(safeContent)<|im_end|>\n"
        }.joined() + "<|im_start|>assistant\n"
    }
}

private struct LocalGenerationFailure: Error, Sendable {
    let message: String
}
