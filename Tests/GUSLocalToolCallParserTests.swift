import XCTest
@testable import IysCodeMovilCore

final class GUSLocalToolCallParserTests: XCTestCase {
    private var tools: [ToolDefinition] {
        [
            ToolDefinition(
                name: "read_file",
                description: "Read a file",
                parameters: .init(
                    properties: [
                        "path": .init(type: "string", description: nil, enumValues: nil),
                        "encoding": .init(type: "string", description: nil, enumValues: ["utf-8", "utf-16"])
                    ],
                    required: ["path"]
                )
            ),
            ToolDefinition(
                name: "edit_file",
                description: "Edit exact text",
                parameters: .init(
                    properties: [
                        "path": .init(type: "string", description: nil, enumValues: nil),
                        "old_text": .init(type: "string", description: nil, enumValues: nil),
                        "new_text": .init(type: "string", description: nil, enumValues: nil),
                        "replace_all": .init(type: "boolean", description: nil, enumValues: nil)
                    ],
                    required: ["path", "old_text", "new_text"]
                )
            )
        ]
    }

    func testParsesOneStrictAllowedToolCall() throws {
        let raw = #"<GUS_TOOL_CALL>{"name":"edit_file","arguments":{"path":"Sources/App.swift","old_text":"old","new_text":"new","replace_all":false}}</GUS_TOOL_CALL>"#
        let call = try XCTUnwrap(GUSLocalToolCallParser.parse(raw, allowedTools: tools))
        XCTAssertEqual(call.name, "edit_file")
        XCTAssertEqual(call.arguments["path"], "Sources/App.swift")
        XCTAssertEqual(call.arguments["replace_all"], "false")
    }

    func testRejectsUntaggedToolLookingJSON() {
        let raw = #"{"name":"read_file","arguments":{"path":"README.md"}}"#
        XCTAssertNil(GUSLocalToolCallParser.parse(raw, allowedTools: tools))
    }

    func testRejectsUnknownToolAndExtraArguments() {
        let unknown = #"<GUS_TOOL_CALL>{"name":"shell","arguments":{"command":"pwd"}}</GUS_TOOL_CALL>"#
        XCTAssertNil(GUSLocalToolCallParser.parse(unknown, allowedTools: tools))

        let extra = #"<GUS_TOOL_CALL>{"name":"read_file","arguments":{"path":"README.md","command":"pwd"}}</GUS_TOOL_CALL>"#
        XCTAssertNil(GUSLocalToolCallParser.parse(extra, allowedTools: tools))
    }

    func testRejectsMissingRequiredFieldAndWrongScalarType() {
        let missing = #"<GUS_TOOL_CALL>{"name":"read_file","arguments":{}}</GUS_TOOL_CALL>"#
        XCTAssertNil(GUSLocalToolCallParser.parse(missing, allowedTools: tools))

        let wrongType = #"<GUS_TOOL_CALL>{"name":"edit_file","arguments":{"path":"a","old_text":"x","new_text":"y","replace_all":"yes"}}</GUS_TOOL_CALL>"#
        XCTAssertNil(GUSLocalToolCallParser.parse(wrongType, allowedTools: tools))
    }

    func testRejectsStringOutsideDeclaredEnum() {
        let invalid = #"<GUS_TOOL_CALL>{"name":"read_file","arguments":{"path":"README.md","encoding":"utf-32"}}</GUS_TOOL_CALL>"#
        XCTAssertNil(GUSLocalToolCallParser.parse(invalid, allowedTools: tools))

        let valid = #"<GUS_TOOL_CALL>{"name":"read_file","arguments":{"path":"README.md","encoding":"utf-8"}}</GUS_TOOL_CALL>"#
        XCTAssertEqual(GUSLocalToolCallParser.parse(valid, allowedTools: tools)?.arguments["encoding"], "utf-8")
    }

    func testRejectsMultipleCallsOrSurroundingText() {
        let multiple = #"<GUS_TOOL_CALL>{"name":"read_file","arguments":{"path":"a"}}</GUS_TOOL_CALL><GUS_TOOL_CALL>{"name":"read_file","arguments":{"path":"b"}}</GUS_TOOL_CALL>"#
        XCTAssertNil(GUSLocalToolCallParser.parse(multiple, allowedTools: tools))

        let prose = #"Voy a leerlo. <GUS_TOOL_CALL>{"name":"read_file","arguments":{"path":"a"}}</GUS_TOOL_CALL>"#
        XCTAssertNil(GUSLocalToolCallParser.parse(prose, allowedTools: tools))
    }
}
