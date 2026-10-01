import XCTest
@testable import IysCodeMovilCore

final class MiniAgentEditingToolsTests: XCTestCase {
    private func makeWorkspace(_ prefix: String) throws -> IOSWorkspace {
        try IOSWorkspace(rootName: "\(prefix)_\(UUID().uuidString)")
    }

    func testCatalogContainsMiniAgentEditingSurface() async throws {
        let ws = try makeWorkspace("miniagent_catalog")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let executor = MiniAgentFileSystemToolExecutor(workspace: ws)
        let names = await executor.availableTools.map(\.name).sorted()
        XCTAssertEqual(names, [
            "append_file", "copy_file", "create_directory", "delete_file", "edit_file", "file_info",
            "list_directory", "move_file", "read_file", "read_file_range", "replace_lines",
            "search_files", "search_text", "write_file"
        ])
    }

    func testEveryMutationRequiresFreshApproval() async throws {
        let ws = try makeWorkspace("miniagent_approval")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let executor = MiniAgentFileSystemToolExecutor(workspace: ws)
        let mutations = Set(["append_file", "copy_file", "create_directory", "delete_file", "edit_file", "move_file", "replace_lines", "write_file"])
        let tools = await executor.availableTools
        for tool in tools where mutations.contains(tool.name) {
            XCTAssertTrue(tool.capabilities.isDestructive, "\(tool.name) must enter the approval path")
            XCTAssertTrue(tool.capabilities.requiresApprovalEveryTime, "\(tool.name) must ask every time")
        }

        let denied = await executor.execute(.init(name: "write_file", arguments: ["path": "blocked.txt", "content": "no"]), approval: nil)
        XCTAssertNotNil(denied.error)
        let blockedExists = await ws.fileExists(at: "blocked.txt")
        XCTAssertFalse(blockedExists)
    }

    func testEditFileReplacesOneExactOccurrenceAndRejectsAmbiguity() async throws {
        let ws = try makeWorkspace("miniagent_edit")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let executor = MiniAgentFileSystemToolExecutor(workspace: ws)

        try await ws.writeFile(at: "note.txt", data: Data("alpha beta gamma".utf8))
        let edited = await executor.execute(.init(name: "edit_file", arguments: [
            "path": "note.txt", "old_text": "beta", "new_text": "BETA"
        ]), approval: .allowOnce)
        XCTAssertNil(edited.error)
        let editedData = try await ws.readFile(at: "note.txt")
        XCTAssertEqual(String(data: editedData, encoding: .utf8), "alpha BETA gamma")

        try await ws.writeFile(at: "ambiguous.txt", data: Data("x x x".utf8))
        let ambiguous = await executor.execute(.init(name: "edit_file", arguments: [
            "path": "ambiguous.txt", "old_text": "x", "new_text": "y"
        ]), approval: .allowOnce)
        XCTAssertNotNil(ambiguous.error)
        let ambiguousData = try await ws.readFile(at: "ambiguous.txt")
        XCTAssertEqual(String(data: ambiguousData, encoding: .utf8), "x x x")
    }

    func testReplaceLinesAndReadRangeUseOneBasedInclusiveLines() async throws {
        let ws = try makeWorkspace("miniagent_lines")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let executor = MiniAgentFileSystemToolExecutor(workspace: ws)
        try await ws.writeFile(at: "lines.txt", data: Data("one\ntwo\nthree\nfour\n".utf8))

        let replace = await executor.execute(.init(name: "replace_lines", arguments: [
            "path": "lines.txt", "start_line": "2", "end_line": "3", "content": "TWO\nTHREE"
        ]), approval: .allowOnce)
        XCTAssertNil(replace.error)

        let read = await executor.execute(.init(name: "read_file_range", arguments: [
            "path": "lines.txt", "start_line": "2", "end_line": "3"
        ]))
        XCTAssertNil(read.error)
        XCTAssertEqual(read.output, "2: TWO\n3: THREE")
    }

    func testAppendCopyAndSearchText() async throws {
        let ws = try makeWorkspace("miniagent_helpers")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let executor = MiniAgentFileSystemToolExecutor(workspace: ws)
        try await ws.writeFile(at: "a.txt", data: Data("hello".utf8))

        let appended = await executor.execute(
            .init(name: "append_file", arguments: ["path": "a.txt", "content": " world"]),
            approval: .allowOnce
        )
        XCTAssertNil(appended.error)
        let copied = await executor.execute(
            .init(name: "copy_file", arguments: ["from": "a.txt", "to": "nested/b.txt"]),
            approval: .allowOnce
        )
        XCTAssertNil(copied.error)
        let copiedData = try await ws.readFile(at: "nested/b.txt")
        XCTAssertEqual(String(data: copiedData, encoding: .utf8), "hello world")

        let search = await executor.execute(.init(name: "search_text", arguments: [
            "query": "world", "pattern": "**/*.txt"
        ]))
        XCTAssertNil(search.error)
        XCTAssertTrue(search.output.contains("a.txt"))
        XCTAssertTrue(search.output.contains("nested/b.txt"))
        XCTAssertTrue(search.output.contains("hello world"))
    }

    func testReadRangeAndSearchTextBoundToolOutput() async throws {
        let ws = try makeWorkspace("miniagent_output_bounds")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let executor = MiniAgentFileSystemToolExecutor(workspace: ws)
        let hugeLine = String(repeating: "x", count: 70_000) + " needle"
        try await ws.writeFile(at: "huge.txt", data: Data(hugeLine.utf8))

        let read = await executor.execute(.init(name: "read_file_range", arguments: [
            "path": "huge.txt", "start_line": "1", "end_line": "1"
        ]))
        XCTAssertNil(read.error)
        XCTAssertLessThanOrEqual(read.output.count, 61_000)
        XCTAssertTrue(read.output.contains("truncated"))

        let search = await executor.execute(.init(name: "search_text", arguments: [
            "query": "needle", "pattern": "**/*.txt"
        ]))
        XCTAssertNil(search.error)
        XCTAssertLessThanOrEqual(search.output.count, 61_000)
        XCTAssertTrue(search.output.contains("truncated"))
    }
}
