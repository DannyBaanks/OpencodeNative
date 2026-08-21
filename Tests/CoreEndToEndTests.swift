import XCTest
@testable import OpencodeNativeCore

/// Tests de Workspace / Persistence / Tools / AgentLoop end-to-end.
/// Usan un workspace de tests aislado (raíz en App Support con prefijo único).
final class WorkspaceTests: XCTestCase {
    var workspace: IOSWorkspace!

    override func setUp() async throws {
        workspace = try IOSWorkspace(rootName: "test_workspace_\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: await workspace.rootURL)
    }

    func testCreateAndReadFile() async throws {
        try await workspace.writeFile(at: "test.txt", data: Data("hello".utf8))
        let data = try await workspace.readFile(at: "test.txt")
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
    }

    func testListDirectory() async throws {
        try await workspace.createDirectory(at: "sub")
        try await workspace.writeFile(at: "sub/a.txt", data: Data("1".utf8))
        try await workspace.writeFile(at: "sub/b.txt", data: Data("2".utf8))
        let items = try await workspace.listDirectory(at: "sub")
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { !$0.isDirectory })
    }

    func testMoveFile() async throws {
        try await workspace.writeFile(at: "from.txt", data: Data("x".utf8))
        try await workspace.moveFile(from: "from.txt", to: "to.txt")
        let exists = await workspace.fileExists(at: "to.txt")
        XCTAssertTrue(exists)
        let gone = await workspace.fileExists(at: "from.txt")
        XCTAssertFalse(gone)
    }

    func testDeleteFile() async throws {
        try await workspace.writeFile(at: "doomed.txt", data: Data("x".utf8))
        try await workspace.deleteFile(at: "doomed.txt")
        let exists = await workspace.fileExists(at: "doomed.txt")
        XCTAssertFalse(exists)
    }

    func testPathTraversalBlocked() async throws {
        do {
            _ = try await workspace.readFile(at: "../outside")
            XCTFail("esperaba pathNotInSandbox")
        } catch WorkspaceError.pathNotInSandbox {
            // OK
        } catch {
            XCTFail("error inesperado: \(error)")
        }
    }
}

final class PersistenceTests: XCTestCase {
    var persistence: IOSPersistence!

    override func setUp() async throws {
        persistence = try IOSPersistence()
    }

    func testSaveLoadConversation() async throws {
        var conv = Conversation(id: "t-1", title: "T")
        conv.messages.append(Message(role: .user, content: "hi"))
        try await persistence.saveConversation(conv)
        let loaded = try await persistence.loadConversation(id: "t-1")
        XCTAssertEqual(loaded?.id, "t-1")
        XCTAssertEqual(loaded?.messages.count, 1)
    }

    func testEventLoggingJSONL() async throws {
        let id = UUID().uuidString
        try await persistence.appendEvent(AgentEvent(conversationId: id, type: .userInput, payload: ["content": "x"]))
        let events = try await persistence.loadEvents(conversationId: id, since: nil)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .userInput)
    }

    func testConfigurationRoundtrip() async throws {
        var cfg = Configuration()
        cfg.defaultModelName = "gpt-test"
        cfg.fontSize = 20
        try await persistence.saveConfiguration(cfg)
        let loaded = try await persistence.loadConfiguration()
        XCTAssertEqual(loaded?.defaultModelName, "gpt-test")
        XCTAssertEqual(loaded?.fontSize, 20)
    }
}

final class ToolsDefinitionTests: XCTestCase {
    func testAllEightToolsPresent() async throws {
        let ws = try IOSWorkspace(rootName: "tools_test_\(UUID().uuidString)")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let exec = FileSystemToolExecutor(workspace: ws)
        let names = await exec.availableTools.map { $0.name }.sorted()
        let expected = ["create_directory","delete_file","file_info","list_directory","move_file","read_file","search_files","write_file"]
        XCTAssertEqual(names, expected)
    }

    func testWriteFileIsMarkedDestructive() async throws {
        let ws = try IOSWorkspace(rootName: "destructive_test_\(UUID().uuidString)")
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let exec = FileSystemToolExecutor(workspace: ws)
        let write = await exec.availableTools.first { $0.name == "write_file" }
        XCTAssertTrue(write?.capabilities.isDestructive ?? false)
    }
}

/// End-to-end: AgentLoop con ScriptedModelProvider sobre workspace sandbox real.
/// Verifica el flujo agente → tools → workspace → resultado sin red.
final class AgentEndToEndTests: XCTestCase {
    func testScriptedAgentRunsFullFlowAndWritesWorkspace() async throws {
        let rootName = "e2e_\(UUID().uuidString)"
        let ws = try IOSWorkspace(rootName: rootName)
        let rootURL = await ws.rootURL
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Workspace de persisted: usamos un persistence dedicado
        let ps = try IOSPersistence()
        let provider = ScriptedModelProvider(script: ScriptedModelProvider.demoScript())
        let exec = FileSystemToolExecutor(workspace: ws)
        let ctx = AgentContext(
            conversationId: UUID().uuidString,
            workspace: ws,
            persistence: ps,
            modelProvider: provider,
            toolExecutor: exec,
            systemPrompt: "test",
            maxTurns: 15
        )
        let loop = AgentLoop(context: ctx)

        var events: [AgentLoopEvent] = []
        await loop.setEventHandler { events.append($0) }

        let final = try await loop.run(userInput: "demo list-read-write-verify")

        XCTAssertFalse(final.isEmpty)
        // El script debe haber emitido tool results sin error (write_file, read_file, list_directory)
        let toolResults = events.compactMap { event -> ToolExecutionResult? in
            if case .toolResult(let r) = event { return r } else { return nil }
        }
        XCTAssertFalse(toolResults.isEmpty)
        XCTAssertTrue(toolResults.allSatisfy { $0.error == nil }, "alguna tool falló: \(toolResults)")
        // El archivo notes.txt debe existir y tener 2 líneas al final.
        let exists = await ws.fileExists(at: "notes.txt")
        XCTAssertTrue(exists, "notes.txt no creado por el agente")
        let data = try await ws.readFile(at: "notes.txt")
        let content = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(content.split(separator: "\n", omittingEmptySubsequences: true).count, 2)
    }
}
