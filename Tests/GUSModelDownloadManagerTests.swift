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
