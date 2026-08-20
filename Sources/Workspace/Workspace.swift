import Foundation

/// Capabilities que el workspace declara explícitamente.
/// Cada capability documenta si es posible, restringida, o imposible en iOS.
public struct WorkspaceCapabilities: Codable, Sendable {
    public let listDirectory: Bool = true
    public let readFile: Bool = true
    public let writeFile: Bool = true
    public let createDirectory: Bool = true
    public let moveFile: Bool = true
    public let deleteFile: Bool = true
    public let watchChanges: Bool = false // Requires DispatchSource, limited
    public let securityScopedBookmarks: Bool = false // Requires user interaction + entitlement
    public let arbitraryPaths: Bool = false // Sandbox restricts to app containers
    
    public let restrictions: [String] = [
        "Sandbox: only App Support, Documents, tmp, and bundle (read-only)",
        "No access to system directories, other apps' data, or user home outside picker",
        "File watching limited to directories app owns"
    ]
}

/// Errores específicos del workspace
public enum WorkspaceError: Error, LocalizedError, Sendable {
    case pathNotInSandbox(String)
    case permissionDenied(String)
    case notFound(String)
    case alreadyExists(String)
    case invalidPath(String)
    case watchFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .pathNotInSandbox(let p): return "Path outside sandbox: \(p)"
        case .permissionDenied(let p): return "Permission denied: \(p)"
        case .notFound(let p): return "Not found: \(p)"
        case .alreadyExists(let p): return "Already exists: \(p)"
        case .invalidPath(let p): return "Invalid path: \(p)"
        case .watchFailed(let p): return "Watch failed: \(p)"
        }
    }
}

/// Protocolo para abstracción de workspace.
/// Permite testing y futuras implementaciones (ej. remote workspace).
public protocol Workspace: Sendable {
    var rootURL: URL { get }
    var capabilities: WorkspaceCapabilities { get }
    
    func listDirectory(at path: String) async throws -> [FileInfo]
    func readFile(at path: String) async throws -> Data
    func writeFile(at path: String, data: Data) async throws
    func createDirectory(at path: String) async throws
    func moveFile(from: String, to: String) async throws
    func deleteFile(at path: String) async throws
    func fileExists(at path: String) async -> Bool
    func fileInfo(at path: String) async throws -> FileInfo
}

/// Información de un archivo/directorio
public struct FileInfo: Codable, Sendable, Hashable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date
    public let isReadable: Bool
    public let isWritable: Bool
}

/// Implementación nativa iOS usando FileManager
/// Respeta el sandbox: solo directorios accesibles por la app.
public actor IOSWorkspace: Workspace {
    public let rootURL: URL
    public let capabilities = WorkspaceCapabilities()
    
    private let fileManager = FileManager.default
    private let allowedRoots: [URL]
    
    public init(rootName: String = "workspace") throws {
        // Directorio base en Application Support (persistente, privado a la app)
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("OpencodeNative", isDirectory: true)
        
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        
        self.rootURL = baseDir.appendingPathComponent(rootName, isDirectory: true)
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        
        // Raíces permitidas: workspace + Documents + tmp (para operaciones temporales)
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let tmp = fileManager.temporaryDirectory
        
        self.allowedRoots = [self.rootURL, documents, tmp]
    }
    
    /// Verifica que una ruta relativa está dentro de las raíces permitidas
    private func resolveAndValidate(_ relativePath: String) throws -> URL {
        let cleaned = relativePath.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .filter { !$0.isEmpty && $0 != "." }
            .joined(separator: "/")
        
        // Construir URL relativa al rootURL
        var url = rootURL
        for component in cleaned.split(separator: "/") {
            if component == ".." {
                throw WorkspaceError.pathNotInSandbox("Path traversal not allowed: \(relativePath)")
            }
            url.appendPathComponent(String(component))
        }
        
        // Verificar que está dentro de alguna raíz permitida
        let isAllowed = allowedRoots.contains { allowed in
            url.path.hasPrefix(allowed.path)
        }
        
        if !isAllowed {
            throw WorkspaceError.pathNotInSandbox("Path not in allowed roots: \(url.path)")
        }
        
        return url
    }
    
    public func listDirectory(at path: String) async throws -> [FileInfo] {
        let url = try resolveAndValidate(path)
        guard fileManager.fileExists(atPath: url.path) else {
            throw WorkspaceError.notFound(path)
        }
        
        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isReadableKey, .isWritableKey
        ], options: [.skipsHiddenFiles])
        
        return contents.map { fileURL in
            let values = try? fileURL.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isReadableKey, .isWritableKey
            ])
            return FileInfo(
                path: fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: ""),
                name: fileURL.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modificationDate: values?.contentModificationDate ?? Date(),
                isReadable: values?.isReadable ?? false,
                isWritable: values?.isWritable ?? false
            )
        }
    }
    
    public func readFile(at path: String) async throws -> Data {
        let url = try resolveAndValidate(path)
        guard fileManager.fileExists(atPath: url.path) else {
            throw WorkspaceError.notFound(path)
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw WorkspaceError.permissionDenied(path)
        }
        return try Data(contentsOf: url)
    }
    
    public func writeFile(at path: String, data: Data) async throws {
        let url = try resolveAndValidate(path)
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }
    
    public func createDirectory(at path: String) async throws {
        let url = try resolveAndValidate(path)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
    
    public func moveFile(from: String, to: String) async throws {
        let fromURL = try resolveAndValidate(from)
        let toURL = try resolveAndValidate(to)
        guard fileManager.fileExists(atPath: fromURL.path) else {
            throw WorkspaceError.notFound(from)
        }
        if fileManager.fileExists(atPath: toURL.path) {
            throw WorkspaceError.alreadyExists(to)
        }
        let parent = toURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try fileManager.moveItem(at: fromURL, to: toURL)
    }
    
    public func deleteFile(at path: String) async throws {
        let url = try resolveAndValidate(path)
        guard fileManager.fileExists(atPath: url.path) else {
            throw WorkspaceError.notFound(path)
        }
        try fileManager.removeItem(at: url)
    }
    
    public func fileExists(at path: String) async -> Bool {
        do {
            let url = try resolveAndValidate(path)
            return fileManager.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }
    
    public func fileInfo(at path: String) async throws -> FileInfo {
        let url = try resolveAndValidate(path)
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isReadableKey, .isWritableKey
        ])
        return FileInfo(
            path: path,
            name: url.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            size: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate ?? Date(),
            isReadable: values.isReadable ?? false,
            isWritable: values.isWritable ?? false
        )
    }
}