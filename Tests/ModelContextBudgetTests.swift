import XCTest
@testable import IysCodeMovilCore

final class ModelContextBudgetTests: XCTestCase {
    private func call(_ id: String) -> ToolCall { ToolCall(id: id, name: "read_file", arguments: ["path": "a.txt"]) }

    func testStoppedToolCallGetsAResultSoTheChatStaysValid() {
        let messages = [
            ModelMessage(role: .system, content: "sys"),
            ModelMessage(role: .user, content: "lee dos archivos"),
            ModelMessage(role: .assistant, content: "", toolCalls: [call("a"), call("b")]),
            ModelMessage(role: .tool, content: "contenido A", toolCallId: "a"),
            // Stop pressed before "b" finished; the user writes again.
            ModelMessage(role: .user, content: "¿y luego?"),
        ]
        let repaired = ModelContextBudget.repairToolPairs(messages)
        XCTAssertEqual(repaired.map(\.role), [.system, .user, .assistant, .tool, .tool, .user])
        XCTAssertEqual(repaired[4].toolCallId, "b")
        XCTAssertEqual(repaired[4].content, ModelContextBudget.cancelledToolNote)
    }

    func testOrphanToolResultsAreDropped() {
        let messages = [
            ModelMessage(role: .user, content: "hola"),
            ModelMessage(role: .tool, content: "sin llamada", toolCallId: "x"),
            ModelMessage(role: .assistant, content: "hola"),
        ]
        XCTAssertEqual(ModelContextBudget.repairToolPairs(messages).map(\.role), [.user, .assistant])
    }

    func testOldTurnsAreDroppedButSystemAndLatestRequestStay() {
        var messages = [ModelMessage(role: .system, content: "sys")]
        for i in 0..<40 {
            messages.append(ModelMessage(role: .user, content: "pregunta \(i) " + String(repeating: "x", count: 300)))
            messages.append(ModelMessage(role: .assistant, content: "respuesta \(i) " + String(repeating: "y", count: 300)))
        }
        messages.append(ModelMessage(role: .user, content: "la última"))
        let fitted = ModelContextBudget.fit(messages, budget: 4_000)
        XCTAssertEqual(fitted.first?.content, "sys")
        XCTAssertEqual(fitted.last?.content, "la última")
        XCTAssertLessThanOrEqual(fitted.reduce(0) { $0 + $1.content.count + 16 }, 4_000)
        XCTAssertTrue(fitted.contains { $0.content.hasPrefix("respuesta 39") }, "the most recent turns are kept")
        XCTAssertFalse(fitted.contains { $0.content.hasPrefix("pregunta 0 ") })
    }

    func testHugeToolOutputIsShortenedAndNeverSplitFromItsCall() {
        let big = String(repeating: "z", count: 500_000)
        let messages = [
            ModelMessage(role: .system, content: "sys"),
            ModelMessage(role: .user, content: "lee el log"),
            ModelMessage(role: .assistant, content: "", toolCalls: [call("a")]),
            ModelMessage(role: .tool, content: big, toolCallId: "a"),
            ModelMessage(role: .assistant, content: "", toolCalls: [call("b")]),
            ModelMessage(role: .tool, content: big, toolCallId: "b"),
        ]
        let fitted = ModelContextBudget.fit(messages, budget: ModelContextBudget.remoteCharacterCap)
        XCTAssertLessThanOrEqual(fitted.reduce(0) { $0 + $1.content.count }, ModelContextBudget.remoteCharacterCap)
        for (index, message) in fitted.enumerated() where message.role == .tool {
            XCTAssertLessThanOrEqual(message.content.count, ModelContextBudget.latestToolOutputLimit + 100)
            let callIDs = fitted[..<index].last { $0.role == .assistant }?.toolCalls?.map(\.id) ?? []
            XCTAssertTrue(callIDs.contains(message.toolCallId ?? ""), "a result always follows its call")
        }
    }

    func testBudgetFollowsTheProvider() {
        let gus = ModelProviderCapabilities(maxTokens: 256, maxContextTokens: 2048, localOnly: true)
        let local = ModelContextBudget.characterBudget(for: gus, reservedOutputTokens: 2048)
        XCTAssertEqual(local, 1_980, "Reserve context for GUS's 14-tool contract and inference framing")
        let remote = ModelProviderCapabilities(maxTokens: 4096, maxContextTokens: 128_000)
        XCTAssertEqual(ModelContextBudget.characterBudget(for: remote, reservedOutputTokens: 2048), ModelContextBudget.remoteCharacterCap)
    }
}
