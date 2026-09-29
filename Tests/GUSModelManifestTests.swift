import XCTest
@testable import IysCodeMovilCore

final class GUSModelManifestTests: XCTestCase {
    func testCatalogPinsAllApprovedArtifactsAndProvenance() {
        let manifests = Dictionary(uniqueKeysWithValues: GUSModelManifest.all.map { ($0.id, $0) })
        XCTAssertEqual(Set(manifests.keys), ["qwen15-18b-q4km", "qwen25-05b-q4km", "smollm2-360m-q4km"])

        let qwen15 = try! XCTUnwrap(manifests["qwen15-18b-q4km"])
        XCTAssertEqual(qwen15.revision, "07800fcba6d5d1df3dfa36e3763374a2c0d9f91b")
        XCTAssertEqual(qwen15.filename, "qwen1_5-1_8b-chat-q4_k_m.gguf")
        XCTAssertEqual(qwen15.byteCount, 1_217_752_928)
        XCTAssertEqual(qwen15.sha256, "702e983c77883426806a2af75d34ab3e462e1b822f9dc23b49e02280c24b2b18")
        XCTAssertEqual(qwen15.repository, "Qwen/Qwen1.5-1.8B-Chat-GGUF")
        XCTAssertEqual(qwen15.licenseName, "Tongyi Qianwen Research License Agreement · non-commercial")
        XCTAssertTrue(qwen15.attribution.contains("JustinLin610"))

        let qwen25 = try! XCTUnwrap(manifests["qwen25-05b-q4km"])
        XCTAssertEqual(qwen25.revision, "9217f5db79a29953eb74d5343926648285ec7e67")
        XCTAssertEqual(qwen25.filename, "qwen2.5-0.5b-instruct-q4_k_m.gguf")
        XCTAssertEqual(qwen25.byteCount, 491_400_032)
        XCTAssertEqual(qwen25.sha256, "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db")
        XCTAssertEqual(qwen25.repository, "Qwen/Qwen2.5-0.5B-Instruct-GGUF")
        XCTAssertEqual(qwen25.licenseName, "Apache License 2.0")

        let smollm = try! XCTUnwrap(manifests["smollm2-360m-q4km"])
        XCTAssertEqual(smollm.revision, "de67c694b3fa2c6e9b45b50f286b2555c5dee2a8")
        XCTAssertEqual(smollm.filename, "smollm2-360m-instruct-q4_k_m.gguf")
        XCTAssertEqual(smollm.byteCount, 270_590_528)
        XCTAssertEqual(smollm.sha256, "8856952e27c65a87618f8347d1d06328c3953af04e8327b6dd1fab6670358fd0")
        XCTAssertEqual(smollm.repository, "mfuntowicz/SmolLM2-360M-Instruct-Q4_K_M-GGUF")
        XCTAssertEqual(smollm.licenseName, "Apache License 2.0")
        XCTAssertTrue(smollm.attribution.contains("HuggingFaceTB"))
        XCTAssertTrue(smollm.attribution.contains("mfuntowicz"))

        for manifest in manifests.values {
            XCTAssertEqual(manifest.sourceURL.scheme, "https")
            XCTAssertEqual(manifest.sourceURL.host, "huggingface.co")
            XCTAssertTrue(manifest.sourceURL.absoluteString.contains("/resolve/\(manifest.revision)/"))
            XCTAssertEqual(manifest.licenseURL.scheme, "https")
        }
    }

    func testCatalogLookupRejectsUnknownModelID() {
        XCTAssertNil(GUSModelManifest.model(id: "user-provided-model"))
    }
}
