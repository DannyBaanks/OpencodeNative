import Foundation

/// Provenance for a GGUF artifact explicitly approved for GUS local use.
///
/// The approved set lives in `Catalog/models.json` and is compiled into
/// `GUSModelCatalog.generated.swift`; it is never fetched at runtime, because
/// the pinned SHA-256 is what authorizes a file to be loaded by llama.cpp.
public struct GUSModelManifest: Sendable, Equatable, Identifiable {
    /// How much we actually know about this model on a phone.
    public enum Evidence: String, Sendable, Equatable {
        /// Pinned and hash-verified only.
        case unmeasured
        /// Loaded and generated with the app's bridge on a desktop CI runner.
        case desktopSmoke
        /// At least one published on-device benchmark (docs/BENCHMARKS.md).
        case deviceMeasured
    }

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
    public let family: String
    public let vendor: String
    public let parameterLabel: String
    public let commercialUse: Bool
    /// A builtin llama.cpp template name; nil uses the template embedded in the GGUF.
    public let chatTemplateOverride: String?
    /// Experimental models are hidden unless the user opts in and accepts the risk.
    public let isExperimental: Bool
    public let evidence: Evidence
    public let architecture: String?
    /// f16 K+V bytes per context token, read from the GGUF header by the pin workflow.
    public let kvBytesPerToken: Int64?
    public let nativeContextLength: Int?
    /// Reasoning models (Qwen3, SmolLM3, Nemotron) spend a 256-token chat budget
    /// inside `<think>` and answer nothing. This model-specific system directive
    /// turns thinking off for chat.
    public let thinkingOffDirective: String?

    public static func model(id: String) -> GUSModelManifest? {
        all.first { $0.id == id }
    }

    /// Conservative estimate of resident memory once loaded with `contextTokens`.
    ///
    /// Weights are memory-mapped but touched on every token, so they count in
    /// full. Unknown KV geometry falls back to a deliberately pessimistic value.
    public func estimatedPeakBytes(contextTokens: Int) -> Int64 {
        let kvPerToken = kvBytesPerToken ?? 256 * 1024
        let kv = kvPerToken * Int64(contextTokens)
        let computeAndRuntime: Int64 = 160 * 1024 * 1024 + byteCount / 10
        return byteCount + kv + computeAndRuntime
    }

    // Internal initializer: used by the generated catalog and by deterministic tests.
    init(id: String = "fixture", modelName: String, repository: String = "fixture/repository",
         filename: String, revision: String, sourceURL: URL, byteCount: Int64, sha256: String,
         licenseName: String = "fixture", licenseURL: URL = URL(string: "https://example.com/license")!,
         attribution: String = "fixture", family: String = "fixture", vendor: String = "fixture",
         parameterLabel: String = "?", commercialUse: Bool = false, chatTemplateOverride: String? = nil,
         isExperimental: Bool = false, evidence: Evidence = .unmeasured, architecture: String? = nil,
         kvBytesPerToken: Int64? = nil, nativeContextLength: Int? = nil, thinkingOffDirective: String? = nil) {
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
        self.family = family
        self.vendor = vendor
        self.parameterLabel = parameterLabel
        self.commercialUse = commercialUse
        self.chatTemplateOverride = chatTemplateOverride
        self.isExperimental = isExperimental
        self.evidence = evidence
        self.architecture = architecture
        self.kvBytesPerToken = kvBytesPerToken
        self.nativeContextLength = nativeContextLength
        self.thinkingOffDirective = thinkingOffDirective
    }
}
