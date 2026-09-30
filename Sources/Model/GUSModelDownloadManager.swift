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
    case interrupted

    public var errorDescription: String? {
        switch self {
        case .invalidSource: return "La dirección no corresponde a un modelo aprobado."
        case .untrustedRedirect: return "La descarga salió de los hosts aprobados de Hugging Face."
        case .invalidResponse: return "Hugging Face devolvió una respuesta no válida."
        case .tooLarge: return "El archivo supera el tamaño aprobado; se canceló la descarga."
        case .wrongSize(let expected, let actual): return "Tamaño incorrecto: se esperaban \(expected) bytes y llegaron \(actual)."
        case .wrongDigest: return "El SHA-256 no coincide. El modelo no se instaló."
        case .insufficientStorage(let required, let available): return "Se necesitan \(required) bytes libres y solo hay \(available)."
        case .fileSystem(let message): return "No pude guardar el modelo: \(message)"
        case .transfer(let message): return "Falló la descarga: \(message)"
        case .interrupted: return "La descarga se interrumpió. Reinténtala; iOS puede tener que empezar desde cero."
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

/// Injectable only for deterministic small-file tests. Production uses the
/// persistent background URLSession below.
public protocol GUSModelTransfer: Sendable {
    func download(from source: URL, to destination: URL, maximumBytes: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
}

private final class BackgroundGUSModelSessionDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    var onProgress: (@Sendable (String, Int64, Int64) -> Void)?
    var onDownloaded: (@Sendable (String, URL, @escaping @Sendable () -> Void) -> Void)?
    var onFailure: (@Sendable (String, Error, @escaping @Sendable () -> Void) -> Void)?
    var onEventsFinished: (() -> Void)?
    private let allowedHosts: Set<String> = ["huggingface.co", "us.aws.cdn.hf.co", "cdn-lfs.huggingface.co", "cas-bridge.xethub.hf.co"]
    private let maximumBytesByID: [String: Int64]
    private let lock = NSLock()
    private var rejectedTasks = Set<Int>()
    private var oversizedTasks = Set<Int>()
    private var backgroundCompletion: (() -> Void)?
    private var pendingProcessing = 0
    private var didFinishEvents = false

    init(maximumBytesByID: [String: Int64]) {
        self.maximumBytesByID = maximumBytesByID
        super.init()
    }

    func setBackgroundCompletion(_ completion: @escaping () -> Void) {
        lock.lock(); backgroundCompletion = completion; lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        if let limit = maximumBytesByID[id], totalBytesWritten > limit {
            lock.lock(); oversizedTasks.insert(downloadTask.taskIdentifier); lock.unlock()
            downloadTask.cancel()
            return
        }
        onProgress?(id, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        guard let response = downloadTask.response as? HTTPURLResponse,
              response.statusCode == 200,
              let finalURL = response.url,
              finalURL.scheme == "https",
              let host = finalURL.host?.lowercased(), allowedHosts.contains(host) else {
            deliverFailure(id: id, error: GUSModelDownloadError.invalidResponse)
            return
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("gus-\(id)-\(UUID().uuidString).download")
        do {
            try FileManager.default.moveItem(at: location, to: temporary)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
            beginProcessing()
            onDownloaded?(id, temporary) { [weak self] in self?.finishProcessing() }
        } catch {
            deliverFailure(id: id, error: GUSModelDownloadError.fileSystem(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https",
              let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            lock.lock(); rejectedTasks.insert(task.taskIdentifier); lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        lock.lock()
        let rejected = rejectedTasks.remove(task.taskIdentifier) != nil
        let oversized = oversizedTasks.remove(task.taskIdentifier) != nil
        lock.unlock()
        if (error as NSError).code == NSURLErrorCancelled && !rejected && !oversized { return }
        let failure: Error = oversized ? GUSModelDownloadError.tooLarge
            : rejected ? GUSModelDownloadError.untrustedRedirect : error
        deliverFailure(id: id, error: failure)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); didFinishEvents = true; lock.unlock()
        finishEventsIfIdle()
    }

    private func beginProcessing() {
        lock.lock(); pendingProcessing += 1; lock.unlock()
    }

    private func finishProcessing() {
        lock.lock(); pendingProcessing = max(0, pendingProcessing - 1); lock.unlock()
        finishEventsIfIdle()
    }

    private func deliverFailure(id: String, error: Error) {
        beginProcessing()
        onFailure?(id, error) { [weak self] in self?.finishProcessing() }
    }

    private func finishEventsIfIdle() {
        lock.lock()
        guard didFinishEvents, pendingProcessing == 0 else { lock.unlock(); return }
        didFinishEvents = false
        let completion = backgroundCompletion
        backgroundCompletion = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onEventsFinished?()
            completion?()
        }
    }
}

@MainActor
public final class GUSModelDownloadManager: ObservableObject {
    public static let backgroundSessionIdentifier = "com.dannybaanks.isycodemovil.gus-model-downloads.v1"
    public static let shared = GUSModelDownloadManager()

    @Published public private(set) var states: [String: GUSModelDownloadState] = [:]
    @Published public private(set) var selectedModelID: String?

    /// Compatibility accessors for existing call sites; new UI uses per-model APIs.
    public var manifest: GUSModelManifest { selectedManifest ?? manifests.values.sorted { $0.id < $1.id }.first ?? GUSModelManifest.qwen15Q4KM }
    public var state: GUSModelDownloadState { state(for: manifest.id) ?? .notDownloaded }
    public var installedModelURL: URL? { selectedModelURL ?? (fixtureMode ? manifests.keys.sorted().first.flatMap { modelURL(id: $0) } : nil) }
    public var selectedManifest: GUSModelManifest? { selectedModelID.flatMap { GUSModelManifest.model(id: $0) } }
    public var selectedModelURL: URL? {
        guard let selectedModelID else { return nil }
        return modelURL(id: selectedModelID)
    }

    private let manifests: [String: GUSModelManifest]
    private let transfers: [String: any GUSModelTransfer]
    private let modelDirectory: URL
    private let legacyModelDirectory: URL?
    private let fixtureMode: Bool
    private let delegate: BackgroundGUSModelSessionDelegate?
    private var backgroundSession: URLSession?
    private var fixtureTasks: [String: Task<Void, Never>] = [:]
    private var activeBackgroundID: String?
    private var cancelledModelIDs = Set<String>()
    private static let activeModelDefaultsKey = "gus.background.activeModelID"

    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.init(catalog: GUSModelManifest.all,
                  modelDirectory: documents.appendingPathComponent("ISyCode/GUS/Models", isDirectory: true),
                  legacyModelDirectory: support.appendingPathComponent("GUS/Models", isDirectory: true))
    }

    private init(catalog: [GUSModelManifest], modelDirectory: URL, legacyModelDirectory: URL?) {
        self.manifests = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        self.transfers = [:]
        self.modelDirectory = modelDirectory
        self.legacyModelDirectory = legacyModelDirectory
        self.fixtureMode = false
        self.delegate = BackgroundGUSModelSessionDelegate(maximumBytesByID: Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.byteCount) }))
        self.selectedModelID = UserDefaults.standard.string(forKey: "gus.selectedModelID")
        self.activeBackgroundID = UserDefaults.standard.string(forKey: Self.activeModelDefaultsKey)
        configureBackgroundSession()
    }

    // Test seam. Keeping it internal prevents arbitrary catalogs from entering production.
    init(manifests: [GUSModelManifest], transfers: [String: any GUSModelTransfer], modelDirectory: URL) {
        self.manifests = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        self.transfers = transfers
        self.modelDirectory = modelDirectory
        self.legacyModelDirectory = nil
        self.fixtureMode = true
        self.delegate = nil
        self.selectedModelID = nil
    }

    init(manifest: GUSModelManifest, transfer: any GUSModelTransfer, modelDirectory: URL,
         legacyModelDirectory: URL? = nil, permitsFixtureManifest: Bool = true) {
        self.manifests = [manifest.id: manifest]
        self.transfers = [manifest.id: transfer]
        self.modelDirectory = modelDirectory
        self.legacyModelDirectory = legacyModelDirectory
        self.fixtureMode = permitsFixtureManifest
        self.delegate = nil
        self.selectedModelID = nil
    }


    public func state(for modelID: String) -> GUSModelDownloadState? { states[modelID] }

    public func modelURL(id modelID: String) -> URL? {
        guard let manifest = manifests[modelID], case .ready(let url) = states[modelID] else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func selectModel(modelID: String) {
        guard modelURL(id: modelID) != nil else { return }
        selectedModelID = modelID
        UserDefaults.standard.set(modelID, forKey: "gus.selectedModelID")
    }

    public func refresh() async {
        for manifest in manifests.values {
            await refresh(manifest: manifest)
        }
        guard !fixtureMode else { return }
        await reconcileBackgroundTasks()
    }

    private func refresh(manifest: GUSModelManifest) async {
        let installed = modelDirectory.appendingPathComponent(manifest.filename)
        if FileManager.default.fileExists(atPath: installed.path) {
            await verifyAndAdopt(installed, manifest: manifest)
            if modelURL(id: manifest.id) != nil {
                clearActiveTransferIfNeeded(modelID: manifest.id)
                return
            }
        }
        let staged = stagingURL(for: manifest)
        if FileManager.default.fileExists(atPath: staged.path) {
            do {
                states[manifest.id] = .verifying
                try await verify(staged, manifest: manifest)
                try prepareModelDirectory()
                try FileManager.default.moveItem(at: staged, to: installed)
                try excludeFromBackup(installed)
                states[manifest.id] = .ready(installed)
                clearActiveTransferIfNeeded(modelID: manifest.id)
                return
            } catch let error as GUSModelDownloadError {
                try? FileManager.default.removeItem(at: staged)
                states[manifest.id] = .failed(error)
                clearActiveTransferIfNeeded(modelID: manifest.id)
                return
            } catch {
                try? FileManager.default.removeItem(at: staged)
                states[manifest.id] = .failed(.fileSystem(error.localizedDescription))
                clearActiveTransferIfNeeded(modelID: manifest.id)
                return
            }
        }
        if manifest.id == GUSModelManifest.qwen15Q4KM.id, let legacyModelDirectory {
            let legacy = legacyModelDirectory.appendingPathComponent(manifest.filename)
            if FileManager.default.fileExists(atPath: legacy.path) {
                do {
                    states[manifest.id] = .verifying
                    try await verify(legacy, manifest: manifest)
                    try prepareModelDirectory()
                    try FileManager.default.moveItem(at: legacy, to: installed)
                    try excludeFromBackup(installed)
                    states[manifest.id] = .ready(installed)
                    return
                } catch {
                    try? FileManager.default.removeItem(at: legacy)
                    states[manifest.id] = .failed(error as? GUSModelDownloadError ?? .wrongDigest)
                    return
                }
            }
        }
        if states[manifest.id] == nil || states[manifest.id] == .verifying { states[manifest.id] = .notDownloaded }
    }

    public func startDownload() async { await startDownload(modelID: manifest.id) }

    public func startDownload(modelID: String) async {
        if !fixtureMode { await reconcileBackgroundTasks() }
        cancelledModelIDs.remove(modelID)
        guard let manifest = manifests[modelID], isApproved(manifest) else {
            states[modelID] = .failed(.invalidSource)
            return
        }
        guard states[modelID] != .ready(modelDirectory.appendingPathComponent(manifest.filename)) else { return }
        guard activeBackgroundID == nil, fixtureTasks.isEmpty else {
            states[modelID] = .failed(.transfer("Ya hay una descarga de modelo en curso."))
            return
        }
        do {
            try prepareModelDirectory()
            try ensureSpace(for: manifest)
            if fixtureMode {
                guard let transfer = transfers[modelID] else { states[modelID] = .failed(.invalidSource); return }
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.performFixtureDownload(manifest, transfer: transfer)
                }
                fixtureTasks[modelID] = task
                await task.value
            } else {
                guard let session = backgroundSession else { states[modelID] = .failed(.transfer("La descarga de fondo no pudo inicializarse.")); return }
                try? FileManager.default.removeItem(at: stagingURL(for: manifest))
                states[modelID] = .downloading(progress: 0)
                activeBackgroundID = modelID
                UserDefaults.standard.set(modelID, forKey: Self.activeModelDefaultsKey)
                let task = session.downloadTask(with: manifest.sourceURL)
                task.taskDescription = modelID
                task.resume()
            }
        } catch let error as GUSModelDownloadError {
            states[modelID] = .failed(error)
        } catch {
            states[modelID] = .failed(.fileSystem(error.localizedDescription))
        }
    }

    public func cancelDownload() { cancelDownload(modelID: manifest.id) }

    public func cancelDownload(modelID: String) {
        cancelledModelIDs.insert(modelID)
        fixtureTasks[modelID]?.cancel()
        if activeBackgroundID == modelID {
            backgroundSession?.getTasksWithCompletionHandler { _, _, downloadTasks in
                downloadTasks.filter { $0.taskDescription == modelID }.forEach { $0.cancel() }
            }
            activeBackgroundID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeModelDefaultsKey)
        }
        if let manifest = manifests[modelID] { try? FileManager.default.removeItem(at: stagingURL(for: manifest)) }
        states[modelID] = .notDownloaded
    }

    public func deleteModel() { deleteModel(modelID: manifest.id) }

    public func deleteModel(modelID: String) {
        cancelDownload(modelID: modelID)
        guard let manifest = manifests[modelID] else { return }
        try? FileManager.default.removeItem(at: modelDirectory.appendingPathComponent(manifest.filename))
        if modelID == GUSModelManifest.qwen15Q4KM.id, let legacyModelDirectory {
            try? FileManager.default.removeItem(at: legacyModelDirectory.appendingPathComponent(manifest.filename))
        }
        states[modelID] = .notDownloaded
        if selectedModelID == modelID {
            selectedModelID = nil
            UserDefaults.standard.removeObject(forKey: "gus.selectedModelID")
        }
    }

    public func verifyInstalledModel() async -> Bool {
        await refresh()
        return selectedModelURL != nil
    }

    public func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.backgroundSessionIdentifier else { completionHandler(); return }
        delegate?.setBackgroundCompletion(completionHandler)
        configureBackgroundSession()
    }

    private func configureBackgroundSession() {
        guard !fixtureMode, backgroundSession == nil, let delegate else { return }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        backgroundSession = session
        delegate.onProgress = { [weak self] id, written, expected in
            Task { @MainActor in
                guard let self, let total = self.manifests[id]?.byteCount, total > 0 else { return }
                self.states[id] = .downloading(progress: min(1, Double(written) / Double(total)))
            }
        }
        delegate.onDownloaded = { [weak self] id, temporary, done in
            Task { @MainActor in
                await self?.acceptBackgroundDownload(id: id, temporary: temporary)
                done()
            }
        }
        delegate.onFailure = { [weak self] id, error, done in
            Task { @MainActor in
                if let self, let manifest = self.manifests[id] {
                    self.activeBackgroundID = nil
                    UserDefaults.standard.removeObject(forKey: Self.activeModelDefaultsKey)
                    try? FileManager.default.removeItem(at: self.stagingURL(for: manifest))
                    self.states[id] = .failed(error as? GUSModelDownloadError ?? .transfer(error.localizedDescription))
                }
                done()
            }
        }
        delegate.onEventsFinished = { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func reconcileBackgroundTasks() async {
        guard let session = backgroundSession else { return }
        await withCheckedContinuation { continuation in
            session.getTasksWithCompletionHandler { [weak self] _, _, tasks in
                Task { @MainActor in
                    guard let self else { continuation.resume(); return }
                    let managed = tasks.filter { task in self.manifests[task.taskDescription ?? ""] != nil }
                    self.activeBackgroundID = managed.first?.taskDescription
                    if let activeID = self.activeBackgroundID {
                        UserDefaults.standard.set(activeID, forKey: Self.activeModelDefaultsKey)
                    } else if let interruptedID = UserDefaults.standard.string(forKey: Self.activeModelDefaultsKey),
                              self.manifests[interruptedID] != nil {
                        if self.modelURL(id: interruptedID) != nil {
                            UserDefaults.standard.removeObject(forKey: Self.activeModelDefaultsKey)
                        } else if let currentState = self.states[interruptedID], case .downloading = currentState {
                            self.states[interruptedID] = .failed(.interrupted)
                        } else if self.states[interruptedID] == nil || self.states[interruptedID] == .notDownloaded {
                            self.states[interruptedID] = .failed(.interrupted)
                        }
                    }
                    for task in managed {
                        guard let id = task.taskDescription, let expected = self.manifests[id]?.byteCount else { continue }
                        let written = task.countOfBytesReceived
                        self.states[id] = .downloading(progress: expected > 0 ? min(1, Double(written) / Double(expected)) : 0)
                    }
                    for (id, state) in self.states where state != .ready(self.modelDirectory.appendingPathComponent(self.manifests[id]?.filename ?? "")) {
                        if case .downloading = state, !managed.contains(where: { $0.taskDescription == id }) {
                            self.states[id] = .failed(.interrupted)
                        }
                    }
                    continuation.resume()
                }
            }
        }
    }

    private func performFixtureDownload(_ manifest: GUSModelManifest, transfer: any GUSModelTransfer) async {
        defer { fixtureTasks[manifest.id] = nil }
        let staging = stagingURL(for: manifest)
        do {
            stateSet(manifest.id, .downloading(progress: 0))
            try? FileManager.default.removeItem(at: staging)
            try await transfer.download(from: manifest.sourceURL, to: staging, maximumBytes: manifest.byteCount) { [weak self] received in
                Task { @MainActor in
                    guard let self else { return }
                    self.stateSet(manifest.id, .downloading(progress: min(1, Double(received) / Double(max(1, manifest.byteCount)))))
                }
            }
            try Task.checkCancellation()
            states[manifest.id] = .verifying
            try await verify(staging, manifest: manifest)
            try Task.checkCancellation()
            let installed = modelDirectory.appendingPathComponent(manifest.filename)
            try? FileManager.default.removeItem(at: installed)
            try FileManager.default.moveItem(at: staging, to: installed)
            try excludeFromBackup(installed)
            states[manifest.id] = .ready(installed)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: staging)
            states[manifest.id] = .notDownloaded
        } catch let error as GUSModelDownloadError {
            try? FileManager.default.removeItem(at: staging)
            states[manifest.id] = .failed(error)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            states[manifest.id] = .failed(.fileSystem(error.localizedDescription))
        }
    }

    private func acceptBackgroundDownload(id: String, temporary: URL) async {
        guard let manifest = manifests[id], !cancelledModelIDs.contains(id) else {
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        let staging = stagingURL(for: manifest)
        do {
            states[id] = .verifying
            try prepareModelDirectory()
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: temporary, to: staging)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
            try await verify(staging, manifest: manifest)
            let installed = modelDirectory.appendingPathComponent(manifest.filename)
            try? FileManager.default.removeItem(at: installed)
            try FileManager.default.moveItem(at: staging, to: installed)
            try excludeFromBackup(installed)
            states[id] = .ready(installed)
            activeBackgroundID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeModelDefaultsKey)
        } catch let error as GUSModelDownloadError {
            try? FileManager.default.removeItem(at: staging)
            states[id] = .failed(error)
            activeBackgroundID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeModelDefaultsKey)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            states[id] = .failed(.fileSystem(error.localizedDescription))
            activeBackgroundID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeModelDefaultsKey)
        }
    }

    private func clearActiveTransferIfNeeded(modelID: String) {
        guard UserDefaults.standard.string(forKey: Self.activeModelDefaultsKey) == modelID else { return }
        UserDefaults.standard.removeObject(forKey: Self.activeModelDefaultsKey)
        if activeBackgroundID == modelID { activeBackgroundID = nil }
    }

    // MARK: Import / export (models survive app reinstalls)

    public struct ImportSummary: Sendable, Equatable {
        public var imported: [String] = []
        public var alreadyInstalled: [String] = []
        /// GGUF files that do not match any catalog pin (size or SHA-256).
        public var rejected: [String] = []
    }

    /// Adopts GGUF files the user picked in Files (single files or folders).
    /// iOS deletes the app container when the app is removed or reinstalled
    /// under a new identifier (common with sideloading), so models kept in
    /// "On My iPhone" or iCloud Drive can be brought back without downloading.
    /// Only files whose size and SHA-256 match a catalog pin are accepted; the
    /// copy is an APFS clone on the same volume, so it costs no extra space.
    public func importModels(from pickedURLs: [URL]) async -> ImportSummary {
        var summary = ImportSummary()
        for picked in pickedURLs {
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            for file in Self.ggufFiles(at: picked) {
                await importFile(file, into: &summary)
            }
        }
        return summary
    }

    /// Verified model files, for "Save a copy to Files".
    public var installedModelFiles: [URL] {
        manifests.keys.sorted().compactMap { modelURL(id: $0) }
    }

    private func importFile(_ file: URL, into summary: inout ImportSummary) async {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? -1
        // Prefer an exact filename match, then any pin with the same size.
        let name = file.lastPathComponent
        let candidates = manifests.values
            .filter { $0.byteCount == size }
            .sorted { ($0.filename == name ? 0 : 1, $0.id) < ($1.filename == name ? 0 : 1, $1.id) }
        guard !candidates.isEmpty else {
            summary.rejected.append(name)
            return
        }
        if let ready = candidates.first(where: { modelURL(id: $0.id) != nil }) {
            summary.alreadyInstalled.append(ready.id)
            return
        }
        for manifest in candidates {
            let staged = stagingURL(for: manifest)
            let installed = modelDirectory.appendingPathComponent(manifest.filename)
            do {
                try prepareModelDirectory()
                try? FileManager.default.removeItem(at: staged)
                states[manifest.id] = .verifying
                try FileManager.default.copyItem(at: file, to: staged)
                try await verify(staged, manifest: manifest)
                try? FileManager.default.removeItem(at: installed)
                try FileManager.default.moveItem(at: staged, to: installed)
                try excludeFromBackup(installed)
                states[manifest.id] = .ready(installed)
                summary.imported.append(manifest.id)
                return
            } catch {
                try? FileManager.default.removeItem(at: staged)
                states[manifest.id] = .notDownloaded
            }
        }
        summary.rejected.append(name)
    }

    /// The picked URL itself if it is a GGUF, otherwise GGUFs up to two levels below it.
    static func ggufFiles(at url: URL) -> [URL] {
        let isGGUF: (URL) -> Bool = { $0.pathExtension.lowercased() == "gguf" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return isGGUF(url) ? [url] : [] }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let child as URL in enumerator {
            if enumerator.level > 2 { enumerator.skipDescendants(); continue }
            if isGGUF(child) { found.append(child) }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func stateSet(_ id: String, _ state: GUSModelDownloadState) { states[id] = state }

    private func stagingURL(for manifest: GUSModelManifest) -> URL {
        modelDirectory.appendingPathComponent("\(manifest.id).\(manifest.filename).partial")
    }

    private func isApproved(_ manifest: GUSModelManifest) -> Bool {
        !fixtureMode ? GUSModelManifest.model(id: manifest.id) == manifest
            && manifest.sourceURL.scheme == "https" && manifest.sourceURL.host == "huggingface.co"
            && manifest.sourceURL.absoluteString.contains("/resolve/\(manifest.revision)/")
            : manifest.sourceURL.scheme == "https" && manifest.sourceURL.host == "huggingface.co"
    }

    private func prepareModelDirectory() throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: modelDirectory.path)
    }

    private func ensureSpace(for manifest: GUSModelManifest) throws {
        let values = try modelDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
        let required = manifest.byteCount + 100_000_000
        guard available >= required else { throw GUSModelDownloadError.insufficientStorage(required: required, available: available) }
    }

    private func verify(_ file: URL, manifest: GUSModelManifest) async throws {
        let result = try await Task.detached(priority: .utility) { () throws -> (Int64, String) in
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard size == manifest.byteCount else { throw GUSModelDownloadError.wrongSize(expected: manifest.byteCount, actual: size) }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }.value
        guard result.0 == manifest.byteCount else { throw GUSModelDownloadError.wrongSize(expected: manifest.byteCount, actual: result.0) }
        guard result.1 == manifest.sha256.lowercased() else { throw GUSModelDownloadError.wrongDigest }
    }

    private func verifyAndAdopt(_ installed: URL, manifest: GUSModelManifest) async {
        states[manifest.id] = .verifying
        do {
            try await verify(installed, manifest: manifest)
            try excludeFromBackup(installed)
            states[manifest.id] = .ready(installed)
        } catch let error as GUSModelDownloadError {
            try? FileManager.default.removeItem(at: installed)
            states[manifest.id] = .failed(error)
            clearActiveTransferIfNeeded(modelID: manifest.id)
        } catch {
            try? FileManager.default.removeItem(at: installed)
            states[manifest.id] = .failed(.fileSystem(error.localizedDescription))
            clearActiveTransferIfNeeded(modelID: manifest.id)
        }
    }

    private func excludeFromBackup(_ file: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = file
        try mutableURL.setResourceValues(values)
    }
}
