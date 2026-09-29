import Foundation

/// Provenance for the only GGUF this release can install.
public struct GUSModelManifest: Sendable, Equatable {
    public let modelName: String
    public let filename: String
    public let revision: String
    public let sourceURL: URL
    public let byteCount: Int64
    public let sha256: String
    public let licenseName: String
    public let attribution: String

    public static let qwen15Q4KM = GUSModelManifest(
        modelName: "Qwen1.5-1.8B-Chat · Q4_K_M",
        filename: "qwen1_5-1_8b-chat-q4_k_m.gguf",
        revision: "07800fcba6d5d1df3dfa36e3763374a2c0d9f91b",
        sourceURL: URL(string: "https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/resolve/07800fcba6d5d1df3dfa36e3763374a2c0d9f91b/qwen1_5-1_8b-chat-q4_k_m.gguf")!,
        byteCount: 1_217_752_928,
        sha256: "702e983c77883426806a2af75d34ab3e462e1b822f9dc23b49e02280c24b2b18",
        licenseName: "Tongyi Qianwen Research License Agreement · non-commercial",
        attribution: "Qwen/Qwen1.5-1.8B-Chat-GGUF; GGUF uploaded by JustinLin610"
    )

    // Internal fixture initializer supports small deterministic downloader tests.
    init(modelName: String, filename: String, revision: String, sourceURL: URL,
         byteCount: Int64, sha256: String, licenseName: String, attribution: String) {
        self.modelName = modelName
        self.filename = filename
        self.revision = revision
        self.sourceURL = sourceURL
        self.byteCount = byteCount
        self.sha256 = sha256.lowercased()
        self.licenseName = licenseName
        self.attribution = attribution
    }
}
