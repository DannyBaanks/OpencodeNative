import XCTest
@testable import IysCodeMovilCore

private actor MiniAgentPromptCaptureEngine: LocalInferenceEngine {
    private(set) var lastMessages: [ModelMessage] = []

    func load(modelURL: URL, contextTokens: Int) async throws {}
    func unload() async {}
    func generate(messages: [ModelMessage], options: GenerationOptions) async throws -> String {
        lastMessages = messages
        return "ok"
    }
    func cancel() async {}
}

final class GUSMiniAgentContextBudgetTests: XCTestCase {
    func testFullMiniAgentCatalogStillLeavesRoomInsideGUSTwoKContext() async throws {
        let ws = try IOSWorkspace(rootName: "gus_context_\(UUID().uuidString)")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let executor = MiniAgentFileSystemToolExecutor(workspace: ws)
        let toolDefinitions = await executor.availableTools.map { tool in
            ToolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: .init(
                    properties: tool.parameters.properties.mapValues {
                        .init(type: $0.type, description: $0.description, enumValues: $0.enumValues)
                    },
                    required: tool.parameters.required
                )
            )
        }
        XCTAssertEqual(toolDefinitions.count, 14)

        let engine = MiniAgentPromptCaptureEngine()
        let provider = GUSLocalModelProvider(
            modelURL: URL(fileURLWithPath: "/fixture/model.gguf"),
            engine: engine
        )
        let rawMessages = [
            ModelMessage(role: .system, content: GUSMobileRole.mobile.systemPrompt),
            ModelMessage(role: .user, content: String(repeating: "contexto largo para editar archivos ", count: 600))
        ]
        let budget = ModelContextBudget.characterBudget(
            for: provider.capabilities,
            reservedOutputTokens: 256
        )
        let fitted = ModelContextBudget.fit(rawMessages, budget: budget)

        _ = try await provider.generate(
            messages: fitted,
            tools: toolDefinitions,
            options: GenerationOptions(maxTokens: 256)
        )

        let sent = await engine.lastMessages
        let promptCharacters = sent.reduce(0) { $0 + $1.content.count + 16 }
        // At the conservative 2.5 chars/token used by ModelContextBudget this is
        // <=1560 input tokens, leaving ~488 tokens for 256 output + llama framing.
        XCTAssertLessThanOrEqual(promptCharacters, 3_900, "full tool contract overflowed GUS's safe 2K envelope")
    }
}
