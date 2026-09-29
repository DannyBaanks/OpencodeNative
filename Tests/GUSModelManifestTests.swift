import XCTest
@testable import IysCodeMovilCore

final class GUSModelManifestTests: XCTestCase {
    func testQwenManifestIsPinnedToReviewedArtifact() {
        let manifest = GUSModelManifest.qwen15Q4KM
        XCTAssertEqual(manifest.revision, "07800fcba6d5d1df3dfa36e3763374a2c0d9f91b")
        XCTAssertEqual(manifest.filename, "qwen1_5-1_8b-chat-q4_k_m.gguf")
        XCTAssertEqual(manifest.byteCount, 1_217_752_928)
        XCTAssertEqual(manifest.sha256, "702e983c77883426806a2af75d34ab3e462e1b822f9dc23b49e02280c24b2b18")
        XCTAssertEqual(manifest.sourceURL.host, "huggingface.co")
        XCTAssertEqual(manifest.sourceURL.scheme, "https")
        XCTAssertTrue(manifest.sourceURL.absoluteString.contains("/resolve/\(manifest.revision)/"))
    }
}
