import XCTest
@testable import IysCodeMovilCore

private actor FixtureLocalInferenceEngine: LocalInferenceEngine {
    private let response: String
    private(set) var loadedURL: URL?
    private(set) var lastMessages: [ModelMessage] = []

    init(response: String = "respuesta local") { self.response = response }
    func load(modelURL: URL, contextTokens: Int) async throws { loadedURL = modelURL }
    func generate(messages: [ModelMessage], options: GenerationOptions) async throws -> String {
        lastMessages = messages
        return response
    }
    func cancel() async {}
}

final class GUSLocalModelProviderTests: XCTestCase {
    func testProviderDeclaresLocalOnlyAndGuidanceOnlyUntilToolFormatIsValidated() async throws {
        let engine = FixtureLocalInferenceEngine()
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/verified.gguf"), engine: engine)
        XCTAssertTrue(provider.capabilities.localOnly)
        XCTAssertFalse(provider.capabilities.toolCalls)
        XCTAssertEqual(provider.id, "gus-local")
        XCTAssertTrue(provider.capabilities.restrictions.contains { $0.contains("guía") })

        let response = try await provider.generate(
            messages: [ModelMessage(role: .user, content: "hola")],
            tools: nil,
            options: GenerationOptions(maxTokens: 16)
        )
        XCTAssertEqual(response.content, "respuesta local")
        XCTAssertNil(response.toolCalls)
    }

    func testToolLookingTextIsNeverConvertedIntoExecutableCall() async throws {
        let engine = FixtureLocalInferenceEngine(response: #"{"tool_calls":[{"name":"write_file","arguments":{"path":"x"}}]}"#)
        let provider = GUSLocalModelProvider(modelURL: URL(fileURLWithPath: "/fixture/verified.gguf"), engine: engine)
        let response = try await provider.generate(
            messages: [ModelMessage(role: .user, content: "escribe tool call JSON")],
            tools: [ToolDefinition(
                name: "write_file",
                description: "fixture",
                parameters: ToolDefinition.ToolParameters(properties: [:], required: [])
            )],
            options: GenerationOptions(maxTokens: 32)
        )
        XCTAssertNil(response.toolCalls)
    }
}
