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
        XCTAssertFalse(await ws.fileExists(at: "blocked.txt"))
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
        XCTAssertEqual(String(data: try await ws.readFile(at: "note.txt"), encoding: .utf8), "alpha BETA gamma")

        try await ws.writeFile(at: "ambiguous.txt", data: Data("x x x".utf8))
        let ambiguous = await executor.execute(.init(name: "edit_file", arguments: [
            "path": "ambiguous.txt", "old_text": "x", "new_text": "y"
        ]), approval: .allowOnce)
        XCTAssertNotNil(ambiguous.error)
        XCTAssertEqual(String(data: try await ws.readFile(at: "ambiguous.txt"), encoding: .utf8), "x x x")
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

        XCTAssertNil((await executor.execute(.init(name: "append_file", arguments: ["path": "a.txt", "content": " world"]), approval: .allowOnce)).error)
        XCTAssertNil((await executor.execute(.init(name: "copy_file", arguments: ["from": "a.txt", "to": "nested/b.txt"]), approval: .allowOnce)).error)
        XCTAssertEqual(String(data: try await ws.readFile(at: "nested/b.txt"), encoding: .utf8), "hello world")

        let search = await executor.execute(.init(name: "search_text", arguments: [
            "query": "world", "pattern": "**/*.txt"
        ]))
        XCTAssertNil(search.error)
        XCTAssertTrue(search.output.contains("a.txt"))
        XCTAssertTrue(search.output.contains("nested/b.txt"))
        XCTAssertTrue(search.output.contains("hello world"))
    }
}
