import CryptoKit
import Foundation
import XCTest
@testable import IysCodeMovilCore

private struct FixtureModelTransfer: GUSModelTransfer {
    let bytes: Data
    let failure: GUSModelDownloadError?

    func download(from source: URL, to destination: URL, maximumBytes: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        if let failure { throw failure }
        guard Int64(bytes.count) <= maximumBytes else { throw GUSModelDownloadError.tooLarge }
        try bytes.write(to: destination)
        progress(Int64(bytes.count))
    }
}

private actor RetryCount {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private struct RetryModelTransfer: GUSModelTransfer {
    let bytes: Data
    let counter: RetryCount
    func download(from source: URL, to destination: URL, maximumBytes: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard await counter.next() > 1 else { throw GUSModelDownloadError.transfer("temporary network failure") }
        try bytes.write(to: destination)
        progress(Int64(bytes.count))
    }
}

private struct WaitingModelTransfer: GUSModelTransfer {
    func download(from source: URL, to destination: URL, maximumBytes: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        try Task.checkCancellation()
    }
}

@MainActor
final class GUSModelDownloadManagerTests: XCTestCase {
    func testValidFixtureIsInstalledOnlyAfterDigestVerification() async throws {
        let bytes = Data("small model fixture".utf8)
        let (manager, directory) = makeManager(bytes: bytes, expectedBytes: Int64(bytes.count), expectedDigest: digest(bytes))
        defer { try? FileManager.default.removeItem(at: directory) }

        await manager.startDownload()

        guard case .ready(let url) = manager.state else { return XCTFail("Expected verified model to be ready") }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".partial"))
    }

    func testWrongDigestRemovesStagedFileAndDoesNotBecomeReady() async throws {
        let bytes = Data("tampered fixture".utf8)
        let (manager, directory) = makeManager(bytes: bytes, expectedBytes: Int64(bytes.count), expectedDigest: String(repeating: "0", count: 64))
        defer { try? FileManager.default.removeItem(at: directory) }

        await manager.startDownload()

        XCTAssertEqual(manager.state, .failed(.wrongDigest))
        XCTAssertNil(manager.installedModelURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixture.gguf.partial").path))
    }

    func testWrongSizeRemovesStagedFileAndDoesNotBecomeReady() async throws {
        let bytes = Data("short".utf8)
        let (manager, directory) = makeManager(bytes: bytes, expectedBytes: 99, expectedDigest: digest(bytes))
        defer { try? FileManager.default.removeItem(at: directory) }

        await manager.startDownload()

        XCTAssertEqual(manager.state, .failed(.wrongSize(expected: 99, actual: Int64(bytes.count))))
        XCTAssertNil(manager.installedModelURL)
    }

    func testUntrustedRedirectFailsClosed() async throws {
        let bytes = Data("fixture".utf8)
        let (manager, directory) = makeManager(bytes: bytes, expectedBytes: Int64(bytes.count), expectedDigest: digest(bytes), failure: .untrustedRedirect)
        defer { try? FileManager.default.removeItem(at: directory) }

        await manager.startDownload()

        XCTAssertEqual(manager.state, .failed(.untrustedRedirect))
        XCTAssertNil(manager.installedModelURL)
    }

    func testInterruptedTransferCannotExposePartialModel() async throws {
        let bytes = Data("fixture".utf8)
        let (manager, directory) = makeManager(bytes: bytes, expectedBytes: Int64(bytes.count), expectedDigest: digest(bytes), failure: .transfer("connection lost"))
        defer { try? FileManager.default.removeItem(at: directory) }

        await manager.startDownload()

        XCTAssertNil(manager.installedModelURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixture.gguf").path))
    }

    func testOversizedFixtureIsRejectedBeforeInstallation() async {
        let bytes = Data("too much".utf8)
        let (manager, directory) = makeManager(bytes: bytes, expectedBytes: 3, expectedDigest: digest(bytes))
        defer { try? FileManager.default.removeItem(at: directory) }
        await manager.startDownload()
        XCTAssertEqual(manager.state, .failed(.tooLarge))
        XCTAssertNil(manager.installedModelURL)
    }

    func testHTTPFailureIsRecoverableAndNeverReady() async {
        let bytes = Data("fixture".utf8)
        let (manager, directory) = makeManager(bytes: bytes, expectedBytes: Int64(bytes.count), expectedDigest: digest(bytes), failure: .invalidResponse)
        defer { try? FileManager.default.removeItem(at: directory) }
        await manager.startDownload()
        XCTAssertEqual(manager.state, .failed(.invalidResponse))
        XCTAssertNil(manager.installedModelURL)
    }

    func testCompletedStagingFileIsVerifiedAndPromotedOnRefresh() async throws {
        let bytes = Data("verified staged model".utf8)
        let (manager, directory) = makeManager(bytes: bytes, expectedBytes: Int64(bytes.count), expectedDigest: digest(bytes))
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent("fixture.fixture.gguf.partial"))

        await manager.refresh()

        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(manager.modelURL(id: "fixture"))), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixture.fixture.gguf.partial").path))
    }

    func testDeletingOneModelPreservesOtherVerifiedModels() async throws {
        let bytesA = Data("model a".utf8)
        let bytesB = Data("model b".utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = fixtureManifest(id: "fixture-a", filename: "a.gguf", bytes: bytesA)
        let b = fixtureManifest(id: "fixture-b", filename: "b.gguf", bytes: bytesB)
        let manager = GUSModelDownloadManager(manifests: [a, b], transfers: [
            a.id: FixtureModelTransfer(bytes: bytesA, failure: nil),
            b.id: FixtureModelTransfer(bytes: bytesB, failure: nil)
        ], modelDirectory: directory)
        await manager.startDownload(modelID: a.id)
        await manager.startDownload(modelID: b.id)

        manager.deleteModel(modelID: a.id)

        XCTAssertNil(manager.modelURL(id: a.id))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(manager.modelURL(id: b.id))), bytesB)
    }

    func testUnknownBackgroundSessionDoesNotRetainSystemCompletionHandler() {
        var didComplete = false
        GUSModelDownloadManager.shared.handleBackgroundEvents(identifier: "unexpected.session") {
            didComplete = true
        }
        XCTAssertTrue(didComplete)
    }

    func testBackgroundSessionIdentifierIsStableAndVersioned() {
        XCTAssertEqual(GUSModelDownloadManager.backgroundSessionIdentifier, "com.dannybaanks.isycodemovil.gus-model-downloads.v1")
    }

    func testRetryAfterTransferErrorCanInstallVerifiedModel() async throws {
        let bytes = Data("retryable model".utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = fixtureManifest(id: "retry-fixture", filename: "retry.gguf", bytes: bytes)
        let transfer = RetryModelTransfer(bytes: bytes, counter: RetryCount())
        let manager = GUSModelDownloadManager(manifest: manifest, transfer: transfer, modelDirectory: directory)

        await manager.startDownload()
        XCTAssertEqual(manager.state, .failed(.transfer("temporary network failure")))
        await manager.startDownload()

        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(manager.modelURL(id: manifest.id))), bytes)
    }

    func testFreshInstallDoesNotStartDownloadAutomatically() async throws {
        let bytes = Data("fixture".utf8)
        let (manager, directory) = makeManager(bytes: bytes, expectedBytes: Int64(bytes.count), expectedDigest: digest(bytes))
        defer { try? FileManager.default.removeItem(at: directory) }

        await manager.refresh()

        XCTAssertEqual(manager.state, .notDownloaded)
        XCTAssertNil(manager.installedModelURL)
    }

    func testCorruptCachedModelIsRemovedInsteadOfBecomingReady() async throws {
        let bytes = Data("verified fixture".utf8)
        let (manager, directory) = makeManager(bytes: bytes, expectedBytes: Int64(bytes.count), expectedDigest: digest(bytes))
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = directory.appendingPathComponent("fixture.gguf")
        try Data("tampered".utf8).write(to: cached)

        await manager.refresh()

        XCTAssertNil(manager.installedModelURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
    }

    func testDeleteRemovesVerifiedModelAndClearsReadyState() async throws {
        let bytes = Data("verified fixture".utf8)
        let (manager, directory) = makeManager(bytes: bytes, expectedBytes: Int64(bytes.count), expectedDigest: digest(bytes))
        defer { try? FileManager.default.removeItem(at: directory) }
        await manager.startDownload()
        guard case .ready(let installed) = manager.state else { return XCTFail("Expected verified model") }

        manager.deleteModel()

        XCTAssertNil(manager.installedModelURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(manager.state, .notDownloaded)
    }

    func testCancellationDoesNotInstallOrExposePartialFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bytes = Data("fixture".utf8)
        let manifest = GUSModelManifest(
            modelName: "Fixture model", filename: "fixture.gguf", revision: "fixture",
            sourceURL: URL(string: "https://huggingface.co/test/resolve/fixture/model.gguf")!,
            byteCount: Int64(bytes.count), sha256: digest(bytes), licenseName: "fixture", attribution: "fixture"
        )
        let manager = GUSModelDownloadManager(manifest: manifest, transfer: WaitingModelTransfer(), modelDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let download = Task { await manager.startDownload() }
        var downloadStarted = false
        for _ in 0..<100 {
            if case .downloading = manager.state { downloadStarted = true; break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(downloadStarted)

        manager.cancelDownload()
        await download.value

        XCTAssertEqual(manager.state, .notDownloaded)
        XCTAssertNil(manager.installedModelURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixture.gguf.partial").path))
    }

    func testManagerTracksEachModelStateAndSelectionIndependently() async throws {
        let bytesA = Data("model a".utf8)
        let bytesB = Data("model b".utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = fixtureManifest(id: "fixture-a", filename: "a.gguf", bytes: bytesA)
        let b = fixtureManifest(id: "fixture-b", filename: "b.gguf", bytes: bytesB)
        let manager = GUSModelDownloadManager(
            manifests: [a, b],
            transfers: ["fixture-a": FixtureModelTransfer(bytes: bytesA, failure: nil),
                        "fixture-b": FixtureModelTransfer(bytes: bytesB, failure: nil)],
            modelDirectory: directory
        )

        await manager.startDownload(modelID: a.id)
        await manager.startDownload(modelID: b.id)
        manager.selectModel(modelID: b.id)

        XCTAssertNotNil(manager.modelURL(id: a.id))
        XCTAssertEqual(manager.selectedModelID, b.id)
        XCTAssertEqual(manager.selectedModelURL?.lastPathComponent, b.filename)
        XCTAssertEqual(manager.state(for: a.id), .ready(directory.appendingPathComponent(a.filename)))
    }

    func testManagerRejectsUnknownModelIDs() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = GUSModelDownloadManager(manifests: [], transfers: [:], modelDirectory: directory)
        await manager.startDownload(modelID: "unknown")
        XCTAssertEqual(manager.state(for: "unknown"), .failed(.invalidSource))
        XCTAssertNil(manager.modelURL(id: "unknown"))
    }

    private func fixtureManifest(id: String, filename: String, bytes: Data) -> GUSModelManifest {
        GUSModelManifest(id: id, modelName: id, filename: filename, revision: "fixture",
            sourceURL: URL(string: "https://huggingface.co/test/resolve/fixture/\(filename)")!,
            byteCount: Int64(bytes.count), sha256: digest(bytes))
    }

    private func makeManager(bytes: Data, expectedBytes: Int64, expectedDigest: String,
                             failure: GUSModelDownloadError? = nil) -> (GUSModelDownloadManager, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manifest = GUSModelManifest(
            modelName: "Fixture model", filename: "fixture.gguf", revision: "fixture",
            sourceURL: URL(string: "https://huggingface.co/test/resolve/fixture/model.gguf")!,
            byteCount: expectedBytes, sha256: expectedDigest, licenseName: "fixture license", attribution: "fixture"
        )
        return (GUSModelDownloadManager(manifest: manifest, transfer: FixtureModelTransfer(bytes: bytes, failure: failure), modelDirectory: directory), directory)
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
