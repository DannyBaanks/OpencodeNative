import Foundation

/// Provenance for a GGUF artifact explicitly approved for GUS local use.
public struct GUSModelManifest: Sendable, Equatable, Identifiable {
    public let id: String
    public let modelName: String
    public let repository: String
    public let filename: String
    public let revision: String
    public let sourceURL: URL
    public let byteCount: Int64
    public let sha256: String
    public let licenseName: String
    public let licenseURL: URL
    /// Identifies model family/authorship separately from the GGUF uploader.
    public let attribution: String

    public static let qwen15Q4KM = GUSModelManifest(
        id: "qwen15-18b-q4km",
        modelName: "Qwen1.5-1.8B-Chat · Q4_K_M",
        repository: "Qwen/Qwen1.5-1.8B-Chat-GGUF",
        filename: "qwen1_5-1_8b-chat-q4_k_m.gguf",
        revision: "07800fcba6d5d1df3dfa36e3763374a2c0d9f91b",
        sourceURL: URL(string: "https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/resolve/07800fcba6d5d1df3dfa36e3763374a2c0d9f91b/qwen1_5-1_8b-chat-q4_k_m.gguf")!,
        byteCount: 1_217_752_928,
        sha256: "702e983c77883426806a2af75d34ab3e462e1b822f9dc23b49e02280c24b2b18",
        licenseName: "Tongyi Qianwen Research License Agreement · non-commercial",
        licenseURL: URL(string: "https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/blob/07800fcba6d5d1df3dfa36e3763374a2c0d9f91b/LICENSE")!,
        attribution: "Qwen model; GGUF uploaded by JustinLin610"
    )

    public static let qwen25Q4KM = GUSModelManifest(
        id: "qwen25-05b-q4km",
        modelName: "Qwen2.5-0.5B-Instruct · Q4_K_M",
        repository: "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
        filename: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
        revision: "9217f5db79a29953eb74d5343926648285ec7e67",
        sourceURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/9217f5db79a29953eb74d5343926648285ec7e67/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
        byteCount: 491_400_032,
        sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
        licenseName: "Apache License 2.0",
        licenseURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/blob/9217f5db79a29953eb74d5343926648285ec7e67/LICENSE")!,
        attribution: "Qwen2.5 model; GGUF repository maintained by Qwen"
    )

    public static let smolLM2Q4KM = GUSModelManifest(
        id: "smollm2-360m-q4km",
        modelName: "SmolLM2-360M-Instruct · Q4_K_M",
        repository: "mfuntowicz/SmolLM2-360M-Instruct-Q4_K_M-GGUF",
        filename: "smollm2-360m-instruct-q4_k_m.gguf",
        revision: "de67c694b3fa2c6e9b45b50f286b2555c5dee2a8",
        sourceURL: URL(string: "https://huggingface.co/mfuntowicz/SmolLM2-360M-Instruct-Q4_K_M-GGUF/resolve/de67c694b3fa2c6e9b45b50f286b2555c5dee2a8/smollm2-360m-instruct-q4_k_m.gguf")!,
        byteCount: 270_590_528,
        sha256: "8856952e27c65a87618f8347d1d06328c3953af04e8327b6dd1fab6670358fd0",
        licenseName: "Apache License 2.0",
        licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
        attribution: "SmolLM2 model family by HuggingFaceTB; GGUF uploaded/converted by mfuntowicz"
    )

    public static let all: [GUSModelManifest] = [qwen15Q4KM, qwen25Q4KM, smolLM2Q4KM]

    public static func model(id: String) -> GUSModelManifest? {
        all.first { $0.id == id }
    }

    // Internal fixture initializer supports small deterministic downloader tests.
    init(id: String = "fixture", modelName: String, repository: String = "fixture/repository",
         filename: String, revision: String, sourceURL: URL, byteCount: Int64, sha256: String,
         licenseName: String = "fixture", licenseURL: URL = URL(string: "https://example.com/license")!,
         attribution: String = "fixture") {
        self.id = id
        self.modelName = modelName
        self.repository = repository
        self.filename = filename
        self.revision = revision
        self.sourceURL = sourceURL
        self.byteCount = byteCount
        self.sha256 = sha256.lowercased()
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.attribution = attribution
    }
}
