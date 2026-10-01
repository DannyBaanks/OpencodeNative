import XCTest
@testable import IysCodeMovilCore

final class MiniAgentEditingToolTests: XCTestCase {
    private func makeWorkspace(_ prefix: String) throws -> IOSWorkspace {
        try IOSWorkspace(rootName: "\(prefix)_\(UUID().uuidString)")
    }

    func testEveryFilesystemMutationRequiresFreshApproval() async throws {
        let ws = try makeWorkspace("mutation_permissions")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let exec = MiniAgentFileSystemToolExecutor(workspace: ws)
        let tools = await exec.availableTools
        let mutationNames = ["write_file", "edit_file", "replace_lines", "append_file", "copy_file", "create_directory", "move_file", "delete_file"]

        for name in mutationNames {
            let tool = try XCTUnwrap(tools.first { $0.name == name }, "missing \(name)")
            XCTAssertTrue(tool.capabilities.isDestructive, "\(name) must be approval-gated")
            XCTAssertTrue(tool.capabilities.requiresApprovalEveryTime, "\(name) must require fresh approval")
        }
    }

    func testEditFileReplacesOneExactUniqueOccurrence() async throws {
        let ws = try makeWorkspace("edit_unique")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try await ws.writeFile(at: "main.swift", data: Data("let answer = 41\nprint(answer)\n".utf8))
        let exec = MiniAgentFileSystemToolExecutor(workspace: ws)

        let result = await exec.execute(ToolInvocation(name: "edit_file", arguments: [
            "path": "main.swift",
            "old_text": "let answer = 41",
            "new_text": "let answer = 42"
        ]))

        XCTAssertNil(result.error)
        let data = try await ws.readFile(at: "main.swift")
        XCTAssertEqual(String(data: data, encoding: .utf8), "let answer = 42\nprint(answer)\n")
    }

    func testEditFileRejectsAmbiguousReplacementUnlessReplaceAllIsExplicit() async throws {
        let ws = try makeWorkspace("edit_ambiguous")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try await ws.writeFile(at: "dupe.txt", data: Data("cat cat".utf8))
        let exec = MiniAgentFileSystemToolExecutor(workspace: ws)

        let denied = await exec.execute(ToolInvocation(name: "edit_file", arguments: [
            "path": "dupe.txt",
            "old_text": "cat",
            "new_text": "dog"
        ]))
        XCTAssertNotNil(denied.error)
        XCTAssertEqual(String(data: try await ws.readFile(at: "dupe.txt"), encoding: .utf8), "cat cat")

        let allowed = await exec.execute(ToolInvocation(name: "edit_file", arguments: [
            "path": "dupe.txt",
            "old_text": "cat",
            "new_text": "dog",
            "replace_all": "true"
        ]))
        XCTAssertNil(allowed.error)
        XCTAssertEqual(String(data: try await ws.readFile(at: "dupe.txt"), encoding: .utf8), "dog dog")
    }

    func testAppendFilePreservesExistingContent() async throws {
        let ws = try makeWorkspace("append")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try await ws.writeFile(at: "notes.txt", data: Data("one\n".utf8))
        let exec = MiniAgentFileSystemToolExecutor(workspace: ws)

        let result = await exec.execute(ToolInvocation(name: "append_file", arguments: [
            "path": "notes.txt",
            "content": "two\n"
        ]))

        XCTAssertNil(result.error)
        XCTAssertEqual(String(data: try await ws.readFile(at: "notes.txt"), encoding: .utf8), "one\ntwo\n")
    }

    func testCopyFileCopiesBytesAndRefusesToOverwriteDestination() async throws {
        let ws = try makeWorkspace("copy")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let original = Data([0x00, 0x01, 0x7f, 0xff])
        try await ws.writeFile(at: "source.bin", data: original)
        let exec = MiniAgentFileSystemToolExecutor(workspace: ws)

        let copied = await exec.execute(ToolInvocation(name: "copy_file", arguments: [
            "from": "source.bin",
            "to": "nested/copy.bin"
        ]))
        XCTAssertNil(copied.error)
        XCTAssertEqual(try await ws.readFile(at: "nested/copy.bin"), original)

        let overwrite = await exec.execute(ToolInvocation(name: "copy_file", arguments: [
            "from": "source.bin",
            "to": "nested/copy.bin"
        ]))
        XCTAssertNotNil(overwrite.error)
        XCTAssertEqual(try await ws.readFile(at: "nested/copy.bin"), original)
    }
}
