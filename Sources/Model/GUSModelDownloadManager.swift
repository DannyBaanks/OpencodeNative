import Combine
import CryptoKit
import Foundation

public enum GUSModelDownloadError: Error, LocalizedError, Equatable, Sendable {
    case invalidSource
    case untrustedRedirect
    case invalidResponse
    case tooLarge
    case wrongSize(expected: Int64, actual: Int64)
    case wrongDigest
    case insufficientStorage(required: Int64, available: Int64)
    case fileSystem(String)
    case transfer(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSource: return "La dirección del modelo no coincide con la revisión aprobada."
        case .untrustedRedirect: return "La descarga intentó salir del host de Hugging Face aprobado."
        case .invalidResponse: return "Hugging Face devolvió una respuesta no válida."
        case .tooLarge: return "El archivo supera el tamaño aprobado; se canceló la descarga."
        case .wrongSize(let expected, let actual): return "Tamaño incorrecto: se esperaban \(expected) bytes y llegaron \(actual)."
        case .wrongDigest: return "El SHA-256 no coincide. El modelo no se instaló."
        case .insufficientStorage(let required, let available): return "Se necesitan \(required) bytes libres y solo hay \(available)."
        case .fileSystem(let message): return "No pude guardar el modelo: \(message)"
        case .transfer(let message): return "Falló la descarga: \(message)"
        }
    }
}

public enum GUSModelDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case verifying
    case ready(URL)
    case failed(GUSModelDownloadError)
}

public protocol GUSModelTransfer: Sendable {
    func download(from source: URL, to destination: URL, maximumBytes: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
}

private final class GUSRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>
    private let lock = NSLock()
    private var rejectedRedirect = false

    init(allowedHosts: Set<String>) { self.allowedHosts = allowedHosts }

    var didRejectRedirect: Bool {
        lock.lock(); defer { lock.unlock() }
        return rejectedRedirect
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https",
              let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            lock.lock(); rejectedRedirect = true; lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private actor URLSessionGUSModelTransfer: GUSModelTransfer {
    // Redirects observed for the immutable Qwen file route. Keep exact hosts; no suffix matching.
    private let redirectGuard = GUSRedirectGuard(allowedHosts: ["us.aws.cdn.hf.co"])

    func download(from source: URL, to destination: URL, maximumBytes: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        let session = URLSession(configuration: .ephemeral, delegate: redirectGuard, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(from: source)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if redirectGuard.didRejectRedirect { throw GUSModelDownloadError.untrustedRedirect }
            throw GUSModelDownloadError.transfer("No se completó la descarga segura. Revisa la conexión e inténtalo otra vez.")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GUSModelDownloadError.invalidResponse
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), length > maximumBytes {
            throw GUSModelDownloadError.tooLarge
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: destination) }
        catch { throw GUSModelDownloadError.fileSystem(error.localizedDescription) }
        defer { try? handle.close() }

        var buffer = [UInt8]()
        buffer.reserveCapacity(64 * 1024)
        var received: Int64 = 0
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                received += 1
                guard received <= maximumBytes else { throw GUSModelDownloadError.tooLarge }
                buffer.append(byte)
                if buffer.count == 64 * 1024 {
                    try handle.write(contentsOf: Data(buffer))
                    buffer.removeAll(keepingCapacity: true)
                    progress(received)
                }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: Data(buffer)) }
            progress(received)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if redirectGuard.didRejectRedirect { throw GUSModelDownloadError.untrustedRedirect }
            throw error
        }
    }
}

@MainActor
public final class GUSModelDownloadManager: ObservableObject {
    public static let shared = GUSModelDownloadManager()
    @Published public private(set) var state: GUSModelDownloadState = .notDownloaded

    public let manifest: GUSModelManifest
    private let transfer: any GUSModelTransfer
    private let modelDirectory: URL
    private let permitsFixtureManifest: Bool
    private var downloadTask: Task<Void, Never>?

    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(manifest: .qwen15Q4KM, transfer: URLSessionGUSModelTransfer(), modelDirectory: support.appendingPathComponent("GUS/Models", isDirectory: true), permitsFixtureManifest: false)
    }

    init(manifest: GUSModelManifest, transfer: any GUSModelTransfer, modelDirectory: URL, permitsFixtureManifest: Bool = true) {
        self.manifest = manifest
        self.transfer = transfer
        self.modelDirectory = modelDirectory
        self.permitsFixtureManifest = permitsFixtureManifest
    }

    public var installedModelURL: URL? {
        guard case .ready(let url) = state else { return nil }
        return url
    }

    public func refresh() async {
        // A sheet can reappear while the singleton downloader is still active.
        // Do not replace its progress state with `notDownloaded` mid-transfer.
        guard downloadTask == nil else { return }
        let installed = modelDirectory.appendingPathComponent(manifest.filename)
        guard FileManager.default.fileExists(atPath: installed.path) else {
            state = .notDownloaded
            return
        }
        state = .verifying
        do {
            try await verify(installed)
            try excludeFromBackup(installed)
            state = .ready(installed)
        } catch let error as GUSModelDownloadError {
            try? FileManager.default.removeItem(at: installed)
            state = .failed(error)
        } catch {
            state = .failed(.fileSystem(error.localizedDescription))
        }
    }

    public func startDownload() async {
        guard downloadTask == nil else { await downloadTask?.value; return }
        guard (permitsFixtureManifest || manifest == .qwen15Q4KM),
              manifest.sourceURL.scheme == "https",
              manifest.sourceURL.host == "huggingface.co" else {
            state = .failed(.invalidSource)
            return
        }
        downloadTask = Task { [weak self] in await self?.performDownload() }
        await downloadTask?.value
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        let staging = modelDirectory.appendingPathComponent("\(manifest.filename).partial")
        try? FileManager.default.removeItem(at: staging)
        state = .notDownloaded
    }

    public func deleteModel() {
        cancelDownload()
        let installed = modelDirectory.appendingPathComponent(manifest.filename)
        try? FileManager.default.removeItem(at: installed)
        state = .notDownloaded
    }

    public func verifyInstalledModel() async -> Bool {
        await refresh()
        return installedModelURL != nil
    }

    private func performDownload() async {
        defer { downloadTask = nil }
        do {
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            let values = try modelDirectory.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            let available: Int64
            if let importantCapacity = values.volumeAvailableCapacityForImportantUsage {
                available = importantCapacity
            } else if let capacity = values.volumeAvailableCapacity {
                available = Int64(capacity)
            } else {
                available = 0
            }
            let required = manifest.byteCount + 100_000_000
            guard available >= required else {
                throw GUSModelDownloadError.insufficientStorage(required: required, available: available)
            }
            let staging = modelDirectory.appendingPathComponent("\(manifest.filename).partial")
            try? FileManager.default.removeItem(at: staging)
            state = .downloading(progress: 0)
            try await transfer.download(from: manifest.sourceURL, to: staging, maximumBytes: manifest.byteCount) { [weak self] received in
                Task { @MainActor in
                    guard let self, self.downloadTask?.isCancelled == false,
                          case .downloading = self.state else { return }
                    self.state = .downloading(progress: min(1, Double(received) / Double(self.manifest.byteCount)))
                }
            }
            try Task.checkCancellation()
            state = .verifying
            try await verify(staging)
            try Task.checkCancellation()
            let installed = modelDirectory.appendingPathComponent(manifest.filename)
            try? FileManager.default.removeItem(at: installed)
            try FileManager.default.moveItem(at: staging, to: installed)
            try excludeFromBackup(installed)
            state = .ready(installed)
        } catch is CancellationError {
            let staging = modelDirectory.appendingPathComponent("\(manifest.filename).partial")
            try? FileManager.default.removeItem(at: staging)
            state = .notDownloaded
        } catch let error as GUSModelDownloadError {
            let staging = modelDirectory.appendingPathComponent("\(manifest.filename).partial")
            try? FileManager.default.removeItem(at: staging)
            state = .failed(error)
        } catch {
            let staging = modelDirectory.appendingPathComponent("\(manifest.filename).partial")
            try? FileManager.default.removeItem(at: staging)
            state = .failed(.fileSystem(error.localizedDescription))
        }
    }

    private func verify(_ file: URL) async throws {
        let expected = manifest
        let result = try await Task.detached(priority: .utility) { () throws -> (Int64, String) in
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard size == expected.byteCount else {
                throw GUSModelDownloadError.wrongSize(expected: expected.byteCount, actual: size)
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (size, digest)
        }.value
        guard result.0 == manifest.byteCount else {
            throw GUSModelDownloadError.wrongSize(expected: manifest.byteCount, actual: result.0)
        }
        guard result.1 == manifest.sha256.lowercased() else { throw GUSModelDownloadError.wrongDigest }
    }

    private func excludeFromBackup(_ file: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = file
        try mutableURL.setResourceValues(values)
    }
}
