import Foundation

/// File-focused tool surface for the mobile miniagent.
///
/// It deliberately has no shell/process capability. All paths are still
/// resolved by `Workspace`, so the iOS sandbox / user-selected Files grant is
/// the authority boundary. Mutations require an explicit per-operation approval
/// even when this executor is invoked outside AgentLoop.
public actor MiniAgentFileSystemToolExecutor: @preconcurrency ToolExecutor {
    private let workspace: any Workspace
    private let legacy: FileSystemToolExecutor

    private static let maximumFileBytes = 10_000_000
    private static let maximumSearchFileBytes: Int64 = 1_000_000
    private static let maximumSearchResults = 200
    private static let maximumToolOutputCharacters = 60_000
    private static let maximumSearchOutputBytes = 58_000
    private static let maximumSearchLineCharacters = 2_000

    public static let toolNames = Set(tools.map(\.name))

    public init(workspace: any Workspace) {
        self.workspace = workspace
        self.legacy = FileSystemToolExecutor(workspace: workspace)
    }

    public var availableTools: [AgentTool] { Self.tools }

    public func execute(_ invocation: ToolInvocation) async -> ToolExecutionResult {
        await execute(invocation, approval: nil)
    }

    public func execute(_ invocation: ToolInvocation, approval: PermissionResponse.Decision?) async -> ToolExecutionResult {
        let started = Date()
        guard let tool = Self.tools.first(where: { $0.name == invocation.name }) else {
            return failure(invocation, "Unknown tool: \(invocation.name)", started: started)
        }
        if tool.capabilities.isDestructive,
           approval != .allowOnce && approval != .allowAlways {
            return failure(invocation, "Fresh user approval is required for \(invocation.name).", started: started)
        }

        if FileSystemToolExecutor.toolNames.contains(invocation.name) {
            return await legacy.execute(invocation)
        }

        do {
            switch invocation.name {
            case "read_file_range": return try await readFileRange(invocation, started: started)
            case "edit_file": return try await editFile(invocation, started: started)
            case "replace_lines": return try await replaceLines(invocation, started: started)
            case "append_file": return try await appendFile(invocation, started: started)
            case "copy_file": return try await copyFile(invocation, started: started)
            case "search_text": return try await searchText(invocation, started: started)
            default:
                return failure(invocation, "Unknown tool: \(invocation.name)", started: started)
            }
        } catch {
            return failure(invocation, error.localizedDescription, started: started)
        }
    }

    private func readFileRange(_ invocation: ToolInvocation, started: Date) async throws -> ToolExecutionResult {
        let path = try required(invocation, "path")
        let startLine = try positiveInteger(invocation, "start_line")
        let endLine = try positiveInteger(invocation, "end_line")
        guard startLine <= endLine else { throw WorkspaceError.invalidPath("start_line must be <= end_line") }

        let text = try await readUTF8(path)
        let lines = text.components(separatedBy: "\n")
        let logicalCount = text.hasSuffix("\n") ? max(lines.count - 1, 0) : lines.count
        guard startLine <= logicalCount, endLine <= logicalCount else {
            throw WorkspaceError.invalidPath("Requested lines \(startLine)-\(endLine), file has \(logicalCount) lines")
        }
        let output = (startLine...endLine).map { line in
            "\(line): \(lines[line - 1])"
        }.joined(separator: "\n")
        return success(invocation, boundedOutput(output), started: started)
    }

    private func editFile(_ invocation: ToolInvocation, started: Date) async throws -> ToolExecutionResult {
        let path = try required(invocation, "path")
        let oldText = try required(invocation, "old_text")
        let newText = invocation.arguments["new_text"] ?? ""
        let replaceAll = boolean(invocation.arguments["replace_all"] ?? "false")
        guard !oldText.isEmpty else { throw WorkspaceError.invalidPath("old_text must not be empty") }

        let original = try await readUTF8(path)
        let occurrences = original.components(separatedBy: oldText).count - 1
        guard occurrences > 0 else { throw WorkspaceError.notFound("old_text was not found in \(path)") }
        guard replaceAll || occurrences == 1 else {
            throw WorkspaceError.invalidPath("old_text matched \(occurrences) times; make it more specific or set replace_all=true")
        }

        let updated = original.replacingOccurrences(of: oldText, with: newText)
        try await writeUTF8(updated, path: path)
        return success(invocation, "Edited \(path): replaced \(replaceAll ? occurrences : 1) occurrence(s)", started: started)
    }

    private func replaceLines(_ invocation: ToolInvocation, started: Date) async throws -> ToolExecutionResult {
        let path = try required(invocation, "path")
        let startLine = try positiveInteger(invocation, "start_line")
        let endLine = try positiveInteger(invocation, "end_line")
        let replacement = invocation.arguments["content"] ?? ""
        guard startLine <= endLine else { throw WorkspaceError.invalidPath("start_line must be <= end_line") }

        let original = try await readUTF8(path)
        let trailingNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        if trailingNewline, lines.last == "" { lines.removeLast() }
        guard startLine <= lines.count, endLine <= lines.count else {
            throw WorkspaceError.invalidPath("Requested lines \(startLine)-\(endLine), file has \(lines.count) lines")
        }

        var replacementLines = replacement.components(separatedBy: "\n")
        if replacement.hasSuffix("\n"), replacementLines.last == "" { replacementLines.removeLast() }
        lines.replaceSubrange((startLine - 1)...(endLine - 1), with: replacementLines)
        var updated = lines.joined(separator: "\n")
        if trailingNewline { updated += "\n" }
        try await writeUTF8(updated, path: path)
        return success(invocation, "Replaced lines \(startLine)-\(endLine) in \(path)", started: started)
    }

    private func appendFile(_ invocation: ToolInvocation, started: Date) async throws -> ToolExecutionResult {
        let path = try required(invocation, "path")
        let addition = invocation.arguments["content"] ?? ""
        let original: String
        if await workspace.fileExists(at: path) {
            original = try await readUTF8(path)
        } else {
            original = ""
        }
        try await writeUTF8(original + addition, path: path)
        return success(invocation, "Appended \(addition.utf8.count) bytes to \(path)", started: started)
    }

    private func copyFile(_ invocation: ToolInvocation, started: Date) async throws -> ToolExecutionResult {
        let from = try required(invocation, "from")
        let to = try required(invocation, "to")
        let info = try await workspace.fileInfo(at: from)
        guard !info.isDirectory else { throw WorkspaceError.invalidPath("copy_file copies files only") }
        guard !(await workspace.fileExists(at: to)) else { throw WorkspaceError.alreadyExists(to) }
        let data = try await workspace.readFile(at: from)
        guard data.count <= Self.maximumFileBytes else {
            throw WorkspaceError.invalidPath("File too large: \(data.count) bytes (max 10MB)")
        }
        try await workspace.writeFile(at: to, data: data)
        return success(invocation, "Copied \(from) → \(to)", started: started)
    }

    private func searchText(_ invocation: ToolInvocation, started: Date) async throws -> ToolExecutionResult {
        let query = try required(invocation, "query")
        let basePath = invocation.arguments["path"] ?? ""
        let pattern = invocation.arguments["pattern"] ?? "**/*"
        let requestedLimit = Int(invocation.arguments["max_results"] ?? "50") ?? 50
        let limit = min(max(requestedLimit, 1), Self.maximumSearchResults)
        var results: [[String: Any]] = []
        var estimatedBytes = 2
        var didTruncate = false
        var outputBudgetExhausted = false

        func walk(_ directory: String) async throws {
            guard !outputBudgetExhausted, results.count < limit else { return }
            for item in try await workspace.listDirectory(at: directory) {
                guard !outputBudgetExhausted, results.count < limit else { return }
                let relative = directory.isEmpty ? item.name : "\(directory)/\(item.name)"
                if item.isDirectory {
                    try await walk(relative)
                    continue
                }
                guard item.size <= Self.maximumSearchFileBytes, GlobMatcher.match(pattern, relative) else { continue }
                guard let text = String(data: try await workspace.readFile(at: relative), encoding: .utf8) else { continue }
                for (offset, line) in text.components(separatedBy: "\n").enumerated() {
                    guard !outputBudgetExhausted, results.count < limit else { return }
                    if line.localizedCaseInsensitiveContains(query) {
                        let preview: String
                        if line.count > Self.maximumSearchLineCharacters {
                            preview = String(line.prefix(Self.maximumSearchLineCharacters)) + " [truncated]"
                            didTruncate = true
                        } else {
                            preview = line
                        }
                        let candidate: [String: Any] = ["path": relative, "line": offset + 1, "text": preview]
                        let candidateBytes = (try? JSONSerialization.data(withJSONObject: candidate).count) ?? 0
                        if estimatedBytes + candidateBytes + 2 > Self.maximumSearchOutputBytes {
                            didTruncate = true
                            outputBudgetExhausted = true
                            return
                        }
                        results.append(candidate)
                        estimatedBytes += candidateBytes + 1
                    }
                }
            }
        }

        try await walk(basePath)
        if didTruncate {
            results.append(["path": "", "line": 0, "text": "[truncated: long matching text or additional matches omitted]"])
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        return success(invocation, String(data: data, encoding: .utf8) ?? "[]", started: started)
    }

    private func readUTF8(_ path: String) async throws -> String {
        let data = try await workspace.readFile(at: path)
        guard data.count <= Self.maximumFileBytes else {
            throw WorkspaceError.invalidPath("File too large: \(data.count) bytes (max 10MB)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.invalidPath("Miniagent editing tools require UTF-8 text files")
        }
        return text
    }

    private func writeUTF8(_ text: String, path: String) async throws {
        let data = Data(text.utf8)
        guard data.count <= Self.maximumFileBytes else {
            throw WorkspaceError.invalidPath("Content too large: \(data.count) bytes (max 10MB)")
        }
        try await workspace.writeFile(at: path, data: data)
    }

    private func boundedOutput(_ output: String) -> String {
        guard output.count > Self.maximumToolOutputCharacters else { return output }
        let marker = "\n[truncated: tool output exceeded \(Self.maximumToolOutputCharacters) characters]"
        let prefixCount = max(Self.maximumToolOutputCharacters - marker.count, 0)
        return String(output.prefix(prefixCount)) + marker
    }

    private func required(_ invocation: ToolInvocation, _ key: String) throws -> String {
        guard let value = invocation.arguments[key], !value.isEmpty else {
            throw WorkspaceError.invalidPath("\(key) is required")
        }
        return value
    }

    private func positiveInteger(_ invocation: ToolInvocation, _ key: String) throws -> Int {
        guard let raw = invocation.arguments[key], let value = Int(raw), value > 0 else {
            throw WorkspaceError.invalidPath("\(key) must be a positive integer")
        }
        return value
    }

    private func boolean(_ raw: String) -> Bool {
        raw.lowercased() == "true"
    }

    private func success(_ invocation: ToolInvocation, _ output: String, started: Date) -> ToolExecutionResult {
        ToolExecutionResult(toolCallId: invocation.id, output: output, duration: Date().timeIntervalSince(started))
    }

    private func failure(_ invocation: ToolInvocation, _ message: String, started: Date) -> ToolExecutionResult {
        ToolExecutionResult(toolCallId: invocation.id, output: "", error: message, duration: Date().timeIntervalSince(started))
    }

    private static func mutation(_ reason: String) -> AgentTool.ToolCapabilities {
        .init(
            requiresFileSystem: true,
            isDestructive: true,
            restrictions: ["Sandbox: only within the active workspace"],
            approvalReason: reason,
            requiresApprovalEveryTime: true
        )
    }

    private static let readOnly = AgentTool.ToolCapabilities(
        requiresFileSystem: true,
        restrictions: ["Sandbox: only within the active workspace"]
    )

    private static let tools: [AgentTool] = [
        AgentTool(name: "read_file", description: "Read a whole file from the workspace (output is bounded).", properties: [
            "path": .init(type: "string", description: "Relative file path"),
            "encoding": .init(type: "string", description: "utf-8, utf-16, ascii, or latin1", enumValues: ["utf-8", "utf-16", "ascii", "latin1"])
        ], required: ["path"], capabilities: readOnly),
        AgentTool(name: "read_file_range", description: "Read an inclusive 1-based line range from a UTF-8 text file.", properties: [
            "path": .init(type: "string", description: "Relative file path"),
            "start_line": .init(type: "integer", description: "First line, 1-based"),
            "end_line": .init(type: "integer", description: "Last line, inclusive")
        ], required: ["path", "start_line", "end_line"], capabilities: readOnly),
        AgentTool(name: "list_directory", description: "List files and directories inside the workspace.", properties: [
            "path": .init(type: "string", description: "Relative directory path; empty means root"),
            "recursive": .init(type: "boolean", description: "Whether to recurse")
        ], capabilities: readOnly),
        AgentTool(name: "search_files", description: "Find files by glob and optional contained text.", properties: [
            "pattern": .init(type: "string", description: "Glob such as **/*.swift"),
            "path": .init(type: "string", description: "Relative base directory"),
            "content": .init(type: "string", description: "Optional case-insensitive text query")
        ], required: ["pattern"], capabilities: readOnly),
        AgentTool(name: "search_text", description: "Search UTF-8 files and return matching paths, line numbers, and lines.", properties: [
            "query": .init(type: "string", description: "Text to find"),
            "pattern": .init(type: "string", description: "Optional glob; default **/*"),
            "path": .init(type: "string", description: "Optional relative base directory"),
            "max_results": .init(type: "integer", description: "1-200; default 50")
        ], required: ["query"], capabilities: readOnly),
        AgentTool(name: "file_info", description: "Get file or directory metadata.", properties: [
            "path": .init(type: "string", description: "Relative path")
        ], required: ["path"], capabilities: readOnly),
        AgentTool(name: "write_file", description: "Create or replace a file with complete content.", properties: [
            "path": .init(type: "string", description: "Relative file path"),
            "content": .init(type: "string", description: "Complete file content"),
            "encoding": .init(type: "string", description: "utf-8, utf-16, ascii, or latin1", enumValues: ["utf-8", "utf-16", "ascii", "latin1"])
        ], required: ["path", "content"], capabilities: mutation("Write this file with the displayed content?")),
        AgentTool(name: "edit_file", description: "Replace exact UTF-8 text. Ambiguous matches fail unless replace_all=true.", properties: [
            "path": .init(type: "string", description: "Relative file path"),
            "old_text": .init(type: "string", description: "Exact text that must already exist"),
            "new_text": .init(type: "string", description: "Replacement text"),
            "replace_all": .init(type: "boolean", description: "Replace every exact match; default false")
        ], required: ["path", "old_text", "new_text"], capabilities: mutation("Apply this exact text edit?")),
        AgentTool(name: "replace_lines", description: "Replace an inclusive 1-based line range in a UTF-8 text file.", properties: [
            "path": .init(type: "string", description: "Relative file path"),
            "start_line": .init(type: "integer", description: "First line, 1-based"),
            "end_line": .init(type: "integer", description: "Last line, inclusive"),
            "content": .init(type: "string", description: "Replacement text")
        ], required: ["path", "start_line", "end_line", "content"], capabilities: mutation("Replace these lines with the displayed content?")),
        AgentTool(name: "append_file", description: "Append UTF-8 text to a file, creating it when absent.", properties: [
            "path": .init(type: "string", description: "Relative file path"),
            "content": .init(type: "string", description: "Text to append")
        ], required: ["path", "content"], capabilities: mutation("Append this text to the file?")),
        AgentTool(name: "create_directory", description: "Create a directory and missing parents.", properties: [
            "path": .init(type: "string", description: "Relative directory path")
        ], required: ["path"], capabilities: mutation("Create this directory?")),
        AgentTool(name: "copy_file", description: "Copy one file to a new workspace path; destination must not exist.", properties: [
            "from": .init(type: "string", description: "Source relative file path"),
            "to": .init(type: "string", description: "Destination relative file path")
        ], required: ["from", "to"], capabilities: mutation("Copy this file to the displayed destination?")),
        AgentTool(name: "move_file", description: "Move or rename a file or directory; destination must not exist.", properties: [
            "from": .init(type: "string", description: "Source relative path"),
            "to": .init(type: "string", description: "Destination relative path")
        ], required: ["from", "to"], capabilities: mutation("Move or rename this path?")),
        AgentTool(name: "delete_file", description: "Delete a file or directory; recursive=true permits non-empty directories.", properties: [
            "path": .init(type: "string", description: "Relative path to delete"),
            "recursive": .init(type: "boolean", description: "Allow recursive directory deletion; default false")
        ], required: ["path"], capabilities: mutation("Delete this path? Review recursive carefully."))
    ]
}