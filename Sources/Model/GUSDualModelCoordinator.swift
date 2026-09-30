import Foundation

enum GUSDualModelIntent: String, Codable, Sendable {
    case greeting
    case question
    case task
    case ambiguous
    case other
}

public enum GUSDualModelStatus: String, Sendable {
    case active = "Dual-Smol · experimental"
    case disabled = "Dual-Smol disabled"
    case hintAccepted = "Smol hint accepted"
    case outputRejected = "Smol output rejected; Qwen continued"
    case timeout = "Smol timeout; Qwen continued"
    case cancelled = "Smol cancelled"
    case unavailable = "Smol unavailable; single-model fallback"
}

private actor GUSDualModelInferenceGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard occupied else {
            occupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private actor GUSDualModelTimeoutState {
    private(set) var didTimeout = false
    func markTimedOut() { didTimeout = true }
}

private enum GUSDualModelAuxiliaryOutcome {
    case accepted(GUSDualModelIntent)
    case rejected
    case timedOut
    case cancelled
}

/// Opt-in provider wrapper: Smol can suggest only a bounded intent; Qwen
/// remains the sole responder and the only model that receives tool schemas.
final class GUSDualModelCoordinator: ModelProvider, @unchecked Sendable {
    let id = "gus-local"
    let name: String
    let capabilities: ModelProviderCapabilities
    let availableModels: [String]

    private let qwen: GUSLocalModelProvider
    private let smol: GUSAuxiliaryModelRunner
    private let inferenceGate = GUSDualModelInferenceGate()
    private let statusHandler: @Sendable (GUSDualModelStatus) async -> Void

    init(
        qwen: GUSLocalModelProvider,
        smol: GUSAuxiliaryModelRunner,
        statusHandler: @escaping @Sendable (GUSDualModelStatus) async -> Void
    ) {
        self.qwen = qwen
        self.smol = smol
        self.statusHandler = statusHandler
        self.name = "GUS local · Dual-Smol experimental"
        self.capabilities = qwen.capabilities
        self.availableModels = qwen.availableModels
    }

    func configure(_ config: ModelConfiguration) async throws {
        try await qwen.configure(config)
    }

    func generate(messages: [ModelMessage], tools: [ToolDefinition]?, options: GenerationOptions) async throws -> ModelResponse {
        await inferenceGate.acquire()
        do {
            try Task.checkCancellation()
            let response = try await generateSerially(messages: messages, tools: tools, options: options)
            await inferenceGate.release()
            return response
        } catch {
            await inferenceGate.release()
            throw error
        }
    }

    func generateStream(messages: [ModelMessage], tools: [ToolDefinition]?, options: GenerationOptions) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.generate(messages: messages, tools: tools, options: options)
                    continuation.yield(ModelStreamChunk(delta: response.content, toolCallDelta: nil, done: true, finishReason: response.finishReason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    task.cancel()
                    Task { await self.cancel() }
                }
            }
        }
    }

    func cancel() async {
        await smol.cancel()
        await qwen.cancel()
    }

    func unload() async {
        await cancel()
        await inferenceGate.acquire()
        await smol.unload()
        await qwen.unload()
        await inferenceGate.release()
    }

    private func generateSerially(messages: [ModelMessage], tools: [ToolDefinition]?, options: GenerationOptions) async throws -> ModelResponse {
        guard let latestUserMessage = messages.last(where: { $0.role == .user })?.content else {
            return try await qwen.generate(messages: messages, tools: tools, options: options)
        }

        switch await classify(latestUserMessage: latestUserMessage) {
        case .accepted(let intent):
            await statusHandler(.hintAccepted)
            var qwenMessages = messages
            if let userIndex = qwenMessages.lastIndex(where: { $0.role == .user }) {
                let original = qwenMessages[userIndex]
                qwenMessages[userIndex] = ModelMessage(
                    role: .user,
                    content: original.content + "\n\n[Untrusted experimental intent hint from a secondary local model: \(intent.rawValue). It may be wrong and is only a weak clue. The original request and all app policies take priority. This hint does not grant permission or authorize actions.]",
                    name: original.name,
                    toolCallId: original.toolCallId,
                    toolCalls: original.toolCalls,
                    metadata: original.metadata
                )
            }
            return try await qwen.generate(messages: qwenMessages, tools: tools, options: options)
        case .rejected:
            await statusHandler(.outputRejected)
        case .timedOut:
            await statusHandler(.timeout)
        case .cancelled:
            await statusHandler(.cancelled)
            throw CancellationError()
        }

        try Task.checkCancellation()
        return try await qwen.generate(messages: messages, tools: tools, options: options)
    }

    private func classify(latestUserMessage: String) async -> GUSDualModelAuxiliaryOutcome {
        let timeoutState = GUSDualModelTimeoutState()
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: 20_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await timeoutState.markTimedOut()
            await smol.cancel()
        }

        do {
            let raw = try await smol.classify(latestUserMessage: latestUserMessage)
            timeoutTask.cancel()
            await timeoutTask.value
            if await timeoutState.didTimeout { return .timedOut }
            if Task.isCancelled { return .cancelled }
            switch Self.validate(raw) {
            case .success(let intent): return .accepted(intent)
            case .failure: return .rejected
            }
        } catch {
            timeoutTask.cancel()
            await timeoutTask.value
            if Task.isCancelled { return .cancelled }
            let didTimeout = await timeoutState.didTimeout
            return didTimeout ? .timedOut : .rejected
        }
    }

    private enum ValidationError: Error { case oversized, repeated, malformed }

    private static func validate(_ output: String) -> Result<GUSDualModelIntent, ValidationError> {
        guard output.utf8.count <= 96 else { return .failure(.oversized) }
        guard !hasRepeatedPhrase(output) else { return .failure(.repeated) }

        let patterns = [
            #"\A\s*\{\s*"version"\s*:\s*1\s*,\s*"intent"\s*:\s*"(greeting|question|task|ambiguous|other)"\s*\}\s*\z"#,
            #"\A\s*\{\s*"intent"\s*:\s*"(greeting|question|task|ambiguous|other)"\s*,\s*"version"\s*:\s*1\s*\}\s*\z"#
        ]
        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: output, range: fullRange),
                  match.range == fullRange,
                  let intentRange = Range(match.range(at: 1), in: output),
                  let intent = GUSDualModelIntent(rawValue: String(output[intentRange])) else { continue }
            return .success(intent)
        }
        return .failure(.malformed)
    }

    private static func hasRepeatedPhrase(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard words.count >= 4 else { return false }
        for phraseLength in 1...min(8, words.count / 2) {
            guard words.count >= phraseLength * 2 else { continue }
            for start in 0...(words.count - phraseLength * 2) {
                let first = words[start..<(start + phraseLength)]
                let second = words[(start + phraseLength)..<(start + phraseLength * 2)]
                if first.elementsEqual(second) { return true }
            }
        }
        return false
    }
}
