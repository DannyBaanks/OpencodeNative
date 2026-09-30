import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Fixed, deterministic on-device benchmark (protocol v1).
///
/// Greedy decoding, 2K context and fixed prompts, so results from different
/// phones are comparable. The report contains measurements only — no prompt
/// or answer text — and is published through a GitHub issue form.
public struct GUSBenchmarkReport: Codable, Sendable, Equatable {
    public static let schema = "isycode.gus.benchmark/1"

    public enum Status: String, Codable, Sendable { case completed, failed, killed }

    public struct Device: Codable, Sendable, Equatable {
        public var model: String
        public var os: String
        public var ramBytes: Int64
        public var appMemoryLimitBytes: Int64
        public var lowPowerMode: Bool
    }

    public struct Model: Codable, Sendable, Equatable {
        public var id: String
        public var sha256: String
        public var byteCount: Int64
        public var contextTokens: Int
    }

    public struct TaskResult: Codable, Sendable, Equatable {
        public var id: String
        public var promptTokens: Int
        public var generatedTokens: Int
        public var prefillTokensPerSecond: Double
        public var generationTokensPerSecond: Double
        public var template: String
        public var stoppedAtEndOfTurn: Bool
        public var passed: Bool
    }

    public var schema: String = GUSBenchmarkReport.schema
    public var protocolVersion: Int = GUSBenchmark.protocolVersion
    public var runID: String
    public var status: Status
    public var createdAt: Date
    public var appVersion: String
    public var llamaCppCommit: String
    public var device: Device
    public var model: Model
    public var footprintBeforeBytes: Int64
    public var peakFootprintBytes: Int64
    public var loadMilliseconds: Double?
    public var thermalStart: String
    public var thermalEnd: String?
    public var tasks: [TaskResult]
    /// Where it stopped for failed/killed runs: "load" or "task:<id>".
    public var stoppedDuring: String?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case schema, status, device, model, tasks, error
        case protocolVersion = "protocol"
        case runID = "run_id"
        case createdAt = "created_at"
        case appVersion = "app_version"
        case llamaCppCommit = "llama_cpp_commit"
        case footprintBeforeBytes = "footprint_before_bytes"
        case peakFootprintBytes = "peak_footprint_bytes"
        case loadMilliseconds = "load_ms"
        case thermalStart = "thermal_start"
        case thermalEnd = "thermal_end"
        case stoppedDuring = "stopped_during"
    }

    public func json(pretty: Bool = true) -> String {
        let encoder = GUSBenchmark.encoder(pretty: pretty)
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

extension GUSBenchmarkReport.Device {
    enum CodingKeys: String, CodingKey {
        case model, os
        case ramBytes = "ram_bytes"
        case appMemoryLimitBytes = "app_memory_limit_bytes"
        case lowPowerMode = "low_power_mode"
    }
}

extension GUSBenchmarkReport.Model {
    enum CodingKeys: String, CodingKey {
        case id, sha256
        case byteCount = "byte_count"
        case contextTokens = "context_tokens"
    }
}

extension GUSBenchmarkReport.TaskResult {
    enum CodingKeys: String, CodingKey {
        case id, template, passed
        case promptTokens = "prompt_tokens"
        case generatedTokens = "generated_tokens"
        case prefillTokensPerSecond = "prefill_tok_s"
        case generationTokensPerSecond = "gen_tok_s"
        case stoppedAtEndOfTurn = "stopped_at_eot"
    }
}

public enum GUSBenchmark {
    public static let protocolVersion = 1
    /// Must match scripts/build-llama-xcframework.sh (checked by verify-gus-model-manifest.py).
    public static let llamaCppCommit = "842b1880415d6f508f03b789e5ce70194def7bfd"
    public static let contextTokens = 2048

    struct Spec: Sendable {
        let id: String
        let messages: [ModelMessage]
        let maxTokens: Int
        let check: @Sendable (String) -> Bool
    }

    /// Fixed tasks. Changing any prompt or limit requires bumping protocolVersion.
    static let tasks: [Spec] = [
        Spec(id: "short-answer",
             messages: [ModelMessage(role: .system, content: "You are a concise assistant."),
                        ModelMessage(role: .user, content: "What is the capital of France? Answer with one word.")],
             maxTokens: 16,
             check: { $0.localizedCaseInsensitiveContains("paris") }),
        Spec(id: "json-object",
             messages: [ModelMessage(role: .system, content: "You reply with JSON only, no prose and no markdown."),
                        ModelMessage(role: .user, content: #"Return a JSON object with keys "city" and "country" for the capital of Japan."#)],
             maxTokens: 64,
             check: { isJSONObject($0, requiredKeys: ["city", "country"]) }),
        Spec(id: "long-prefill",
             messages: [ModelMessage(role: .system, content: "You are a concise assistant."),
                        ModelMessage(role: .user, content: longPassage + "\n\nSummarize the passage above in one sentence.")],
             maxTokens: 48,
             check: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
        Spec(id: "sustained-generation",
             messages: [ModelMessage(role: .system, content: "You follow instructions exactly."),
                        ModelMessage(role: .user, content: "Count from 1 to 60, separated by single spaces. Output only the numbers.")],
             maxTokens: 160,
             check: { $0.contains("10 11 12") }),
    ]

    /// ~900 tokens of deterministic, public-domain-style filler for prefill timing.
    static let longPassage: String = {
        let sentences = [
            "The harbor town woke early, and the fishermen checked their nets before the tide turned.",
            "A lighthouse keeper wrote the weather in a ledger every hour, as his father had done.",
            "Merchants arrived with salt, rope and lamp oil, and left with dried fish and wool.",
            "In winter the storms closed the road over the hills for weeks at a time.",
            "Children learned to read the sky, the color of the water and the flight of the gulls.",
            "When the railway finally came, the town grew, but the harbor stayed its heart.",
        ]
        return (0..<6).map { round in sentences.map { "\($0) (\(round + 1))" }.joined(separator: " ") }
            .joined(separator: "\n")
    }()

    static func isJSONObject(_ text: String, requiredKeys: [String]) -> Bool {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {  // tolerate a fenced block, but nothing else
            candidate = candidate.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return requiredKeys.allSatisfy { object[$0] != nil }
    }

    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: Pending run (KILLED detection)

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ISyCode/Benchmarks", isDirectory: true)
    }
    public static var pendingURL: URL { directory.appendingPathComponent("pending.json") }

    static func writePending(_ report: GUSBenchmarkReport, to url: URL = pendingURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? encoder(pretty: false).encode(report) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// A pending file left behind means iOS terminated the app mid-run.
    public static func takeKilledRun(from url: URL = pendingURL) -> GUSBenchmarkReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard var report = try? decoder().decode(GUSBenchmarkReport.self, from: data) else { return nil }
        report.status = .killed
        report.error = "iOS terminó la app durante \(report.stoppedDuring ?? "el benchmark") (sin señal capturable; típicamente límite de memoria)."
        return report
    }

    // MARK: Run

    /// Runs the protocol with a dedicated engine. `progress` receives a short step label.
    @MainActor
    public static func run(manifest: GUSModelManifest, modelURL: URL,
                           progress: @escaping @MainActor (String) -> Void) async -> GUSBenchmarkReport {
        let budget = GUSDeviceBudget.current()
        var report = GUSBenchmarkReport(
            runID: UUID().uuidString, status: .failed, createdAt: Date(),
            appVersion: GUSFlightRecorder.bundleVersion(), llamaCppCommit: llamaCppCommit,
            device: .init(model: GUSFlightRecorder.hardwareModel(),
                          os: ProcessInfo.processInfo.operatingSystemVersionString,
                          ramBytes: budget.physicalMemory, appMemoryLimitBytes: budget.appMemoryLimit,
                          lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled),
            model: .init(id: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount, contextTokens: contextTokens),
            footprintBeforeBytes: budget.currentFootprint, peakFootprintBytes: budget.currentFootprint,
            loadMilliseconds: nil, thermalStart: thermalName(ProcessInfo.processInfo.thermalState),
            thermalEnd: nil, tasks: [], stoppedDuring: "load", error: nil)

        let sampler = PeakSampler()
        await sampler.start()
        let engine = LlamaCppInferenceEngine(chatTemplateOverride: manifest.chatTemplateOverride)
        writePending(report)
        progress("Cargando modelo…")
        let loadStart = Date()
        do {
            try await engine.load(modelURL: modelURL, contextTokens: contextTokens)
        } catch {
            report.error = error.localizedDescription
            return await finish(report, sampler: sampler, engine: engine)
        }
        report.loadMilliseconds = Date().timeIntervalSince(loadStart) * 1000

        for spec in tasks {
            report.stoppedDuring = "task:\(spec.id)"
            let peakSoFar = await sampler.peak
            report.peakFootprintBytes = max(report.peakFootprintBytes, peakSoFar)
            writePending(report)
            progress("Tarea \(report.tasks.count + 1)/\(tasks.count): \(spec.id)")
            do {
                let generation = try await engine.generateMeasured(
                    messages: spec.messages, options: GenerationOptions(temperature: 0, maxTokens: spec.maxTokens))
                let s = generation.stats
                report.tasks.append(.init(id: spec.id, promptTokens: s.promptTokens, generatedTokens: s.generatedTokens,
                                          prefillTokensPerSecond: rounded(s.prefillTokensPerSecond),
                                          generationTokensPerSecond: rounded(s.generationTokensPerSecond),
                                          template: s.templateSource.rawValue,
                                          stoppedAtEndOfTurn: s.stoppedAtEndOfTurn,
                                          passed: spec.check(generation.text)))
            } catch {
                report.error = error.localizedDescription
                return await finish(report, sampler: sampler, engine: engine)
            }
        }
        report.status = .completed
        report.stoppedDuring = nil
        return await finish(report, sampler: sampler, engine: engine)
    }

    @MainActor
    private static func finish(_ input: GUSBenchmarkReport, sampler: PeakSampler,
                               engine: LlamaCppInferenceEngine) async -> GUSBenchmarkReport {
        var report = input
        let finalPeak = await sampler.stop()
        report.peakFootprintBytes = max(report.peakFootprintBytes, finalPeak)
        report.thermalEnd = thermalName(ProcessInfo.processInfo.thermalState)
        await engine.unload()
        try? FileManager.default.removeItem(at: pendingURL)
        save(report)
        return report
    }

    static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: History

    static func save(_ report: GUSBenchmarkReport) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder(pretty: true).encode(report) else { return }
        try? data.write(to: directory.appendingPathComponent("\(report.runID).json"), options: .atomic)
    }

    public static func history() -> [GUSBenchmarkReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "pending.json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder().decode(GUSBenchmarkReport.self, from: $0) } }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

/// Samples phys_footprint while the benchmark runs; generation happens off the main actor.
actor PeakSampler {
    private(set) var peak: Int64 = 0
    private var task: Task<Void, Never>?

    func start() {
        peak = GUSDeviceBudget.currentFootprintBytes()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func sample() { peak = max(peak, GUSDeviceBudget.currentFootprintBytes()) }

    func stop() -> Int64 {
        task?.cancel()
        task = nil
        sample()
        return peak
    }
}
