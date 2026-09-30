import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Crash forensics for local models.
///
/// iOS kills an app that exceeds its memory limit with SIGKILL, which no code
/// can observe. So the recorder writes *before* risky work: a small session
/// marker (what the app is doing right now) and an append-only breadcrumb log.
/// If the next launch finds the marker still open, the previous run died, and
/// the last breadcrumbs say where. Fatal signals (a llama.cpp assert → SIGABRT)
/// are recorded by an async-signal-safe trap; MetricKit later adds Apple's own
/// exit reasons and call stacks.
///
/// Privacy: only structural facts are recorded (model id, sizes, token counts,
/// timings, memory). Prompt and answer text are never written.
public final class GUSFlightRecorder: @unchecked Sendable {
    public static let shared = GUSFlightRecorder()

    public struct Breadcrumb: Codable, Sendable, Equatable {
        public let time: Date
        public let event: String
        public let fields: [String: String]
        public let footprintBytes: Int64
        public let availableBytes: Int64
    }

    /// What the app was doing; persisted before each risky phase.
    public struct SessionMarker: Codable, Sendable, Equatable {
        public var sessionID: String
        public var launchedAt: Date
        public var appVersion: String
        public var osVersion: String
        public var deviceModel: String
        public var physicalMemory: Int64
        public var phase: String
        public var phaseStartedAt: Date
        public var modelID: String?
        public var inForeground: Bool
        public var peakFootprintBytes: Int64
    }

    public struct CrashReport: Codable, Sendable, Identifiable, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// The previous run ended without a clean shutdown while in the foreground.
            case uncleanExit
            /// A fatal signal was caught (e.g. SIGABRT from an assert).
            case fatalSignal
            /// Apple's crash diagnostic, delivered by MetricKit (includes call stacks).
            case metricKitCrash
            /// Apple's exit-reason counters (memory limit, watchdog…), from MetricKit.
            case metricKitExits
        }
        public let id: String
        public let kind: Kind
        public let createdAt: Date
        /// One line a person can read: where and why.
        public let summary: String
        public let likelyCause: String
        public let marker: SessionMarker?
        public let breadcrumbs: [Breadcrumb]
        /// Raw MetricKit JSON when available.
        public let appleDiagnostic: String?
    }

    private let lock = NSLock()
    private let directory: URL
    /// Reports produced at this launch about the previous run.
    public private(set) var previousRunReports: [CrashReport] = []
    private var marker: SessionMarker?
    private var breadcrumbHandle: FileHandle?
    private var started = false
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let breadcrumbLimitBytes = 256 * 1024
    static let reportLimit = 50

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ISyCode/Diagnostics", isDirectory: true)
    }

    private var markerURL: URL { directory.appendingPathComponent("session.json") }
    private var breadcrumbsURL: URL { directory.appendingPathComponent("breadcrumbs.jsonl") }
    private var signalURL: URL { directory.appendingPathComponent("signal.txt") }
    private var reportsURL: URL { directory.appendingPathComponent("reports", isDirectory: true) }

    // MARK: Lifecycle

    /// Call once at launch, before any model work. Returns reports created from
    /// the previous run (empty if it ended cleanly).
    @discardableResult
    public func start(appVersion: String = GUSFlightRecorder.bundleVersion(),
                      osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                      deviceModel: String = GUSFlightRecorder.hardwareModel(),
                      installSignalTrap: Bool = true) -> [CrashReport] {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return [] }
        started = true
        try? FileManager.default.createDirectory(at: reportsURL, withIntermediateDirectories: true)

        let previousMarker = (try? Data(contentsOf: markerURL)).flatMap { try? decoder.decode(SessionMarker.self, from: $0) }
        let previousSignal = (try? String(contentsOf: signalURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previousCrumbs = readBreadcrumbs(limit: 40)
        var created: [CrashReport] = []
        if let report = Self.diagnose(marker: previousMarker, signalLine: previousSignal, breadcrumbs: previousCrumbs) {
            save(report)
            created.append(report)
        }
        try? FileManager.default.removeItem(at: signalURL)
        trimBreadcrumbs()

        let now = Date()
        marker = SessionMarker(sessionID: UUID().uuidString, launchedAt: now, appVersion: appVersion,
                               osVersion: osVersion, deviceModel: deviceModel,
                               physicalMemory: Int64(ProcessInfo.processInfo.physicalMemory),
                               phase: "launch", phaseStartedAt: now, modelID: nil, inForeground: true,
                               peakFootprintBytes: GUSDeviceBudget.currentFootprintBytes())
        writeMarker()
        if !FileManager.default.fileExists(atPath: breadcrumbsURL.path) {
            FileManager.default.createFile(atPath: breadcrumbsURL.path, contents: nil)
        }
        breadcrumbHandle = try? FileHandle(forWritingTo: breadcrumbsURL)
        breadcrumbHandle?.seekToEndOfFile()
        if installSignalTrap {
            _ = signalURL.path.withCString { gus_signal_trap_install($0) }
        }
        appendLocked("app.launch", ["version": appVersion, "os": osVersion, "device": deviceModel], sync: true)
        previousRunReports = created
        return created
    }

    /// Marks the session as cleanly ended (app moved to background or terminating).
    /// iOS may later kill a backgrounded app for any reason; that is not a crash.
    public func markBackground() { setForeground(false) }
    public func markForeground() { setForeground(true) }

    private func setForeground(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = marker, current.inForeground != value else { return }
        current.inForeground = value
        marker = current
        writeMarker()
        appendLocked(value ? "app.foreground" : "app.background", [:], sync: false)
    }

    // MARK: Recording

    /// Records the start of a risky phase. The marker is flushed to disk so a
    /// SIGKILL during this phase is attributable on the next launch.
    public func beginPhase(_ phase: String, modelID: String?, fields: [String: String] = [:]) {
        updatePhase(phase, modelID: modelID, inForeground: nil)
        record("\(phase).begin", fields.merging(["model": modelID ?? "-"]) { a, _ in a }, sync: true)
    }

    public func endPhase(_ phase: String, fields: [String: String] = [:]) {
        record("\(phase).end", fields, sync: false)
        updatePhase("idle", modelID: marker?.modelID, inForeground: nil)
    }

    public func record(_ event: String, _ fields: [String: String] = [:], sync: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        appendLocked(event, fields, sync: sync)
    }

    private func appendLocked(_ event: String, _ fields: [String: String], sync: Bool) {
        let footprint = GUSDeviceBudget.currentFootprintBytes()
        let crumb = Breadcrumb(time: Date(), event: event, fields: fields, footprintBytes: footprint,
                               availableBytes: GUSDeviceBudget.availableMemoryBytes())
        guard var line = try? encoder.encode(crumb) else { return }
        line.append(0x0A)
        breadcrumbHandle?.write(line)
        if sync { breadcrumbHandle?.synchronizeFile() }
        if var current = marker, footprint > current.peakFootprintBytes {
            current.peakFootprintBytes = footprint
            marker = current
        }
    }

    private func updatePhase(_ phase: String, modelID: String?, inForeground: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = marker else { return }
        current.phase = phase
        current.phaseStartedAt = Date()
        current.modelID = modelID
        if let inForeground { current.inForeground = inForeground }
        current.peakFootprintBytes = max(current.peakFootprintBytes, GUSDeviceBudget.currentFootprintBytes())
        marker = current
        writeMarker()
    }

    private func writeMarker() {
        guard let marker, let data = try? encoder.encode(marker) else { return }
        try? data.write(to: markerURL, options: .atomic)
    }

    // MARK: Diagnosis (pure; unit-tested)

    static func diagnose(marker: SessionMarker?, signalLine: String?, breadcrumbs: [Breadcrumb]) -> CrashReport? {
        guard let marker else { return nil }
        let signal = signalLine.flatMap { line -> Int32? in
            guard line.hasPrefix("signal=") else { return nil }
            return Int32(line.dropFirst("signal=".count))
        }
        // A backgrounded or idle app killed by iOS is normal housekeeping.
        let risky = marker.phase != "idle" && marker.phase != "launch"
        guard signal != nil || (marker.inForeground && risky) else { return nil }

        let model = marker.modelID ?? "sin modelo"
        let limitHint = breadcrumbs.last.map { crumb -> String in
            let used = ByteCountFormatter.string(fromByteCount: crumb.footprintBytes, countStyle: .memory)
            let free = ByteCountFormatter.string(fromByteCount: crumb.availableBytes, countStyle: .memory)
            return " Última medición: \(used) en uso, \(free) disponibles."
        } ?? ""
        let kind: CrashReport.Kind
        let summary: String
        let cause: String
        if let signal {
            kind = .fatalSignal
            let name = signalName(signal)
            summary = "\(name) durante \(phaseLabel(marker.phase)) · \(model)"
            cause = signal == SIGABRT
                ? "Aborto explícito: normalmente una aserción de llama.cpp (GGML_ASSERT) o un error fatal de Swift."
                : "Acceso inválido a memoria u operación ilegal en código nativo."
        } else {
            kind = .uncleanExit
            summary = "La app terminó durante \(phaseLabel(marker.phase)) · \(model)"
            cause = (marker.phase.hasPrefix("model.load") || marker.phase.hasPrefix("generate") || marker.phase.hasPrefix("benchmark"))
                ? "Probablemente iOS la cerró por exceder su límite de memoria (jetsam).\(limitHint) MetricKit lo confirmará en las próximas horas si fue así."
                : "Cierre no limpio sin señal capturada (memoria, watchdog o cierre forzado).\(limitHint)"
        }
        return CrashReport(id: UUID().uuidString, kind: kind, createdAt: Date(), summary: summary,
                           likelyCause: cause, marker: marker, breadcrumbs: breadcrumbs, appleDiagnostic: nil)
    }

    static func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "model.load": return "la carga del modelo"
        case "generate": return "la generación"
        case "benchmark": return "el benchmark"
        default: return phase
        }
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "señal \(signal)"
        }
    }

    // MARK: Reports

    public func save(_ report: CrashReport) {
        try? FileManager.default.createDirectory(at: reportsURL, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: reportsURL.appendingPathComponent("\(report.id).json"), options: .atomic)
        pruneReports()
    }

    public func reports() -> [CrashReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: reportsURL, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(CrashReport.self, from: $0) } }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func deleteAllReports() {
        try? FileManager.default.removeItem(at: reportsURL)
        try? FileManager.default.createDirectory(at: reportsURL, withIntermediateDirectories: true)
    }

    /// Pretty JSON for sharing (issue attachment); contains no prompt text.
    public func exportJSON(_ report: CrashReport) -> String {
        let pretty = JSONEncoder()
        pretty.dateEncodingStrategy = .iso8601
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? pretty.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public func recentBreadcrumbs(limit: Int = 40) -> [Breadcrumb] {
        lock.lock()
        defer { lock.unlock() }
        breadcrumbHandle?.synchronizeFile()
        return readBreadcrumbs(limit: limit)
    }

    private func pruneReports() {
        let all = reports()
        guard all.count > Self.reportLimit else { return }
        for report in all.dropFirst(Self.reportLimit) {
            try? FileManager.default.removeItem(at: reportsURL.appendingPathComponent("\(report.id).json"))
        }
    }

    private func readBreadcrumbs(limit: Int) -> [Breadcrumb] {
        guard let data = try? Data(contentsOf: breadcrumbsURL) else { return [] }
        return data.split(separator: 0x0A).suffix(limit)
            .compactMap { try? decoder.decode(Breadcrumb.self, from: Data($0)) }
    }

    private func trimBreadcrumbs() {
        guard let data = try? Data(contentsOf: breadcrumbsURL), data.count > Self.breadcrumbLimitBytes else { return }
        let tail = data.suffix(Self.breadcrumbLimitBytes / 2)
        let cut = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
        try? Data(tail[cut...]).write(to: breadcrumbsURL, options: .atomic)
    }

    // MARK: Device facts

    public static func bundleVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Machine identifier such as "iPhone13,2" (not the marketing name).
    public static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
