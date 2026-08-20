import Foundation
import XCTest

@testable import OpencodeNative

final class WorkspaceTests: XCTestCase {
    var workspace: IOSWorkspace!
    
    override func setUp() async throws {
        workspace = try IOSWorkspace(rootName: "test_workspace_\(UUID().uuidString)")
    }
    
    override func tearDown() async throws {
        // Clean up test workspace
        let fm = FileManager.default
        try? fm.removeItem(at: workspace.rootURL)
    }
    
    func testCreateAndReadFile() async throws {
        let path = "test.txt"
        let content = "Hello, OpencodeNative!"
        let data = content.data(using: .utf8)!
        
        try await workspace.writeFile(at: path, data: data)
        let readData = try await workspace.readFile(at: path)
        let readContent = String(data: readData, encoding: .utf8)
        
        XCTAssertEqual(readContent, content)
    }
    
    func testListDirectory() async throws {
        try await workspace.createDirectory(at: "subdir")
        try await workspace.writeFile(at: "subdir/file1.txt", data: Data("1".utf8))
        try await workspace.writeFile(at: "subdir/file2.txt", data: Data("2".utf8))
        
        let items = try await workspace.listDirectory(at: "subdir")
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { !$0.isDirectory })
    }
    
    func testMoveFile() async throws {
        try await workspace.writeFile(at: "source.txt", data: Data("move me".utf8))
        try await workspace.moveFile(from: "source.txt", to: "dest.txt")
        
        let exists = await workspace.fileExists(at: "dest.txt")
        XCTAssertTrue(exists)
        
        let notExists = await workspace.fileExists(at: "source.txt")
        XCTAssertFalse(notExists)
    }
    
    func testDeleteFile() async throws {
        try await workspace.writeFile(at: "to_delete.txt", data: Data("bye".utf8))
        try await workspace.deleteFile(at: "to_delete.txt")
        
        let exists = await workspace.fileExists(at: "to_delete.txt")
        XCTAssertFalse(exists)
    }
    
    func testSearchFiles() async throws {
        try await workspace.createDirectory(at: "src")
        try await workspace.writeFile(at: "src/main.swift", data: Data("print('hello')".utf8))
        try await workspace.writeFile(at: "src/utils.swift", data: Data("func foo()".utf8))
        try await workspace.writeFile(at: "README.md", data: Data("# Project".utf8))
        
        let results = try await workspace.listDirectory(at: "src")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.name.hasSuffix(".swift") })
    }
    
    func testPathTraversalBlocked() async throws {
        do {
            _ = try await workspace.readFile(at: "../../../etc/passwd")
            XCTFail("Should have thrown pathNotInSandbox")
        } catch WorkspaceError.pathNotInSandbox {
            // Expected
        }
    }
    
    func testBinaryFileHandling() async throws {
        let binaryData = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
        try await workspace.writeFile(at: "binary.bin", data: binaryData)
        let readData = try await workspace.readFile(at: "binary.bin")
        XCTAssertEqual(readData, binaryData)
    }
}

final class PersistenceTests: XCTestCase {
    var persistence: IOSPersistence!
    
    override func setUp() async throws {
        persistence = try IOSPersistence()
        // Clean test directories
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let testDir = appSupport.appendingPathComponent("OpencodeNative")
        try? fm.removeItem(at: testDir)
        try fm.createDirectory(at: testDir, withIntermediateDirectories: true)
    }
    
    func testSaveAndLoadConversation() async throws {
        let conversation = Conversation(id: "test-1", title: "Test Conversation")
        conversation.messages.append(Message(role: .user, content: "Hello"))
        conversation.messages.append(Message(role: .assistant, content: "Hi there!"))
        
        try await persistence.saveConversation(conversation)
        let loaded = try await persistence.loadConversation(id: "test-1")
        
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, "test-1")
        XCTAssertEqual(loaded?.messages.count, 2)
    }
    
    func testListConversations() async throws {
        let conv1 = Conversation(id: "c1", title: "First")
        let conv2 = Conversation(id: "c2", title: "Second")
        conv1.messages.append(Message(role: .user, content: "1"))
        conv2.messages.append(Message(role: .user, content: "2"))
        
        try await persistence.saveConversation(conv1)
        try await persistence.saveConversation(conv2)
        
        let list = try await persistence.listConversations()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first?.id, "c2") // Most recent first
    }
    
    func testAgentStatePersistence() async throws {
        var state = AgentState()
        state.currentWorkspace = "my_workspace"
        state.modelProvider = "remote"
        state.modelName = "gpt-4"
        
        try await persistence.saveAgentState(state)
        let loaded = try await persistence.loadAgentState()
        
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.currentWorkspace, "my_workspace")
    }
    
    func testEventLoggingJSONL() async throws {
        let event = AgentEvent(
            conversationId: "conv-1",
            type: .userInput,
            payload: ["content": "test message"]
        )
        
        try await persistence.appendEvent(event)
        let events = try await persistence.loadEvents(conversationId: "conv-1")
        
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .userInput)
    }
    
    func testConfigurationPersistence() async throws {
        var config = Configuration()
        config.defaultModelProvider = "remote"
        config.defaultModelName = "gpt-4"
        config.fontSize = 16
        
        try await persistence.saveConfiguration(config)
        let loaded = try await persistence.loadConfiguration()
        
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.defaultModelName, "gpt-4")
        XCTAssertEqual(loaded?.fontSize, 16)
    }
}

final class ModelProviderTests: XCTestCase {
    func testRemoteProviderCapabilities() {
        let provider = RemoteModelProvider()
        
        XCTAssertEqual(provider.id, "remote")
        XCTAssertEqual(provider.name, "Remote API")
        XCTAssertTrue(provider.capabilities.streaming)
        XCTAssertTrue(provider.capabilities.toolCalls)
        XCTAssertFalse(provider.capabilities.localOnly)
        XCTAssertFalse(provider.capabilities.restrictions.isEmpty)
    }
    
    func testModelConfiguration() {
        let config = ModelConfiguration(
            apiKey: "test-key",
            baseURL: "https://api.example.com/v1",
            timeout: 30
        )
        
        XCTAssertEqual(config.apiKey, "test-key")
        XCTAssertEqual(config.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(config.timeout, 30)
    }
    
    func testGenerationOptions() {
        let options = GenerationOptions(
            model: "gpt-4",
            temperature: 0.5,
            maxTokens: 1000,
            topP: 0.9
        )
        
        XCTAssertEqual(options.model, "gpt-4")
        XCTAssertEqual(options.temperature, 0.5)
        XCTAssertEqual(options.maxTokens, 1000)
        XCTAssertEqual(options.topP, 0.9)
    }
}

final class ToolTests: XCTestCase {
    func testReadFileToolDefinition() {
        let executor = FileSystemToolExecutor(workspace: MockWorkspace())
        let readTool = executor.availableTools.first { $0.name == "read_file" }
        
        XCTAssertNotNil(readTool)
        XCTAssertEqual(readTool?.name, "read_file")
        XCTAssertTrue(readTool?.parameters.required.contains("path") ?? false)
        XCTAssertTrue(readTool?.capabilities.requiresFileSystem ?? false)
    }
    
    func testWriteFileToolDefinition() {
        let executor = FileSystemToolExecutor(workspace: MockWorkspace())
        let writeTool = executor.availableTools.first { $0.name == "write_file" }
        
        XCTAssertNotNil(writeTool)
        XCTAssertTrue(writeTool?.capabilities.isDestructive ?? false)
        XCTAssertTrue(writeTool?.capabilities.requiresFileSystem ?? false)
    }
    
    func testAllToolsPresent() {
        let executor = FileSystemToolExecutor(workspace: MockWorkspace())
        let expectedTools = [
            "read_file", "write_file", "list_directory",
            "search_files", "file_info", "create_directory",
            "delete_file", "move_file"
        ]
        
        let actualTools = executor.availableTools.map { $0.name }
        XCTAssertEqual(actualTools.sorted(), expectedTools.sorted())
    }
}

// Mock workspace for testing tools
private actor MockWorkspace: Workspace {
    let rootURL = URL(fileURLWithPath: "/tmp/mock")
    let capabilities = WorkspaceCapabilities()
    
    func listDirectory(at path: String) async throws -> [FileInfo] { [] }
    func readFile(at path: String) async throws -> Data { Data() }
    func writeFile(at path: String, data: Data) async throws {}
    func createDirectory(at path: String) async throws {}
    func moveFile(from: String, to: String) async throws {}
    func deleteFile(at path: String) async throws {}
    func fileExists(at path: String) async -> Bool { false }
    func fileInfo(at path: String) async throws -> FileInfo {
        FileInfo(path: path, name: "test", isDirectory: false, size: 0, modificationDate: Date(), isReadable: true, isWritable: true)
    }
}