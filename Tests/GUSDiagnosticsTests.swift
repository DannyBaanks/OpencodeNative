import XCTest
@testable import IysCodeMovilCore

final class GUSDiagnosticsTests: XCTestCase {
    private func marker(phase: String, foreground: Bool = true) -> GUSFlightRecorder.SessionMarker {
        .init(sessionID: "s", launchedAt: Date(), appVersion: "1", osVersion: "iOS", deviceModel: "iPhone13,2",
              physicalMemory: 4_000_000_000, phase: phase, phaseStartedAt: Date(), modelID: "qwen3-4b-q4km",
              inForeground: foreground, peakFootprintBytes: 2_900_000_000)
    }

    private func crumb(_ event: String) -> GUSFlightRecorder.Breadcrumb {
        .init(time: Date(), event: event, fields: [:], footprintBytes: 2_900_000_000, availableBytes: 40_000_000)
    }

    func testCleanRunsProduceNoReport() {
        XCTAssertNil(GUSFlightRecorder.diagnose(marker: nil, signalLine: nil, breadcrumbs: []))
        XCTAssertNil(GUSFlightRecorder.diagnose(marker: marker(phase: "idle"), signalLine: nil, breadcrumbs: []))
        XCTAssertNil(GUSFlightRecorder.diagnose(marker: marker(phase: "launch"), signalLine: nil, breadcrumbs: []))
    }

    func testBackgroundKillIsNotACrash() {
        XCTAssertNil(GUSFlightRecorder.diagnose(marker: marker(phase: "generate", foreground: false), signalLine: nil, breadcrumbs: []))
    }

    func testForegroundDeathDuringLoadIsAttributedToMemory() throws {
        let report = try XCTUnwrap(GUSFlightRecorder.diagnose(
            marker: marker(phase: "model.load"), signalLine: nil, breadcrumbs: [crumb("model.load.begin")]))
        XCTAssertEqual(report.kind, .uncleanExit)
        XCTAssertTrue(report.summary.contains("carga del modelo"))
        XCTAssertTrue(report.summary.contains("qwen3-4b-q4km"))
        XCTAssertTrue(report.likelyCause.contains("jetsam"))
        XCTAssertEqual(report.breadcrumbs.count, 1)
    }

    func testCaughtSignalWinsEvenWhenIdle() throws {
        let report = try XCTUnwrap(GUSFlightRecorder.diagnose(
            marker: marker(phase: "generate"), signalLine: "signal=\(SIGABRT)", breadcrumbs: []))
        XCTAssertEqual(report.kind, .fatalSignal)
        XCTAssertTrue(report.summary.hasPrefix("SIGABRT"))
        XCTAssertTrue(report.likelyCause.contains("GGML_ASSERT"))
    }

    func testRecorderRoundTripDetectsUncleanExitOnNextLaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = GUSFlightRecorder(directory: dir)
        XCTAssertTrue(first.start(installSignalTrap: false).isEmpty)
        first.beginPhase("generate", modelID: "smollm2-360m-q4km", fields: ["chars": "12"])
        // Simulate SIGKILL: no endPhase, a fresh process starts.
        let second = GUSFlightRecorder(directory: dir)
        let reports = second.start(installSignalTrap: false)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.marker?.modelID, "smollm2-360m-q4km")
        XCTAssertTrue(reports.first?.breadcrumbs.contains { $0.event == "generate.begin" } ?? false)
        XCTAssertEqual(second.reports().count, 1)
        XCTAssertFalse(second.exportJSON(reports[0]).isEmpty)

        second.endPhase("generate")
        let third = GUSFlightRecorder(directory: dir)
        XCTAssertTrue(third.start(installSignalTrap: false).isEmpty, "a finished phase is a clean exit")
    }

    func testBudgetClassification() {
        XCTAssertEqual(GUSDeviceBudget.classify(peak: 700, limit: 1000), .comfortable)
        XCTAssertEqual(GUSDeviceBudget.classify(peak: 850, limit: 1000), .tight)
        XCTAssertEqual(GUSDeviceBudget.classify(peak: 950, limit: 1000), .unlikely)
        XCTAssertEqual(GUSDeviceBudget.classify(peak: 1, limit: 0), .unlikely)
        let small = GUSDeviceBudget(physicalMemory: 4 << 30, appMemoryLimit: 3 << 30, currentFootprint: 0)
        XCTAssertEqual(small.fit(for: .smolLM2Q4KM), .comfortable)
    }
}

final class GUSBenchmarkTests: XCTestCase {
    func testJSONCheckAcceptsObjectsOnly() {
        XCTAssertTrue(GUSBenchmark.isJSONObject(#"{"city":"Tokyo","country":"Japan"}"#, requiredKeys: ["city", "country"]))
        XCTAssertTrue(GUSBenchmark.isJSONObject("```json\n{\"city\":\"Tokyo\",\"country\":\"Japan\"}\n```", requiredKeys: ["city"]))
        XCTAssertFalse(GUSBenchmark.isJSONObject("Sure! {\"city\":\"Tokyo\"}", requiredKeys: ["city"]))
        XCTAssertFalse(GUSBenchmark.isJSONObject(#"{"city":"Tokyo"}"#, requiredKeys: ["city", "country"]))
    }

    func testProtocolIsStable() {
        XCTAssertEqual(GUSBenchmark.protocolVersion, 1)
        XCTAssertEqual(GUSBenchmark.tasks.map(\.id), ["short-answer", "json-object", "long-prefill", "sustained-generation"])
        XCTAssertGreaterThan(GUSBenchmark.longPassage.utf8.count, 2_500)
    }

    func testPendingRunBecomesKilledReportWithSnakeCaseSchema() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/pending.json")
        let report = GUSBenchmarkReport(
            runID: "r1", status: .failed, createdAt: Date(timeIntervalSince1970: 0), appVersion: "0.1.0 (1)",
            llamaCppCommit: GUSBenchmark.llamaCppCommit,
            device: .init(model: "iPhone13,2", os: "iOS 18", ramBytes: 4, appMemoryLimitBytes: 3, lowPowerMode: false),
            model: .init(id: "qwen3-4b-q4km", sha256: String(repeating: "a", count: 64), byteCount: 1, contextTokens: 2048),
            footprintBeforeBytes: 1, peakFootprintBytes: 2, loadMilliseconds: nil, thermalStart: "nominal",
            thermalEnd: nil, tasks: [], stoppedDuring: "load", error: nil)
        GUSBenchmark.writePending(report, to: url)
        let killed = try XCTUnwrap(GUSBenchmark.takeKilledRun(from: url))
        XCTAssertEqual(killed.status, .killed)
        XCTAssertEqual(killed.stoppedDuring, "load")
        XCTAssertNil(GUSBenchmark.takeKilledRun(from: url), "a killed run is reported once")

        let json = killed.json()
        for key in ["\"schema\"", "\"protocol\"", "\"run_id\"", "\"peak_footprint_bytes\"", "\"app_memory_limit_bytes\"", "\"llama_cpp_commit\""] {
            XCTAssertTrue(json.contains(key), key)
        }
        XCTAssertTrue(json.contains(GUSBenchmarkReport.schema))
    }

    func testReasoningBlocksAreHidden() {
        XCTAssertEqual(LlamaCppInferenceEngine.visibleAnswer("<think>hmm</think>\nParis"), "Paris")
        XCTAssertEqual(LlamaCppInferenceEngine.visibleAnswer("<think>still thinking"), "")
        XCTAssertEqual(LlamaCppInferenceEngine.visibleAnswer("Paris"), "Paris")
        XCTAssertEqual(LlamaCppInferenceEngine.visibleAnswer("draft\n</think>\n\nParis\n"), "Paris")
    }

    func testChatSamplesWithRepetitionPenaltyButBenchmarkStaysGreedy() {
        XCTAssertNil(LlamaCppInferenceEngine.sampling(for: GenerationOptions(temperature: 0, maxTokens: 16)),
                     "temperature 0 must stay greedy so benchmarks are reproducible")
        let chat = try! XCTUnwrap(LlamaCppInferenceEngine.sampling(for: GenerationOptions(temperature: 0.7, maxTokens: 256)))
        XCTAssertEqual(chat.temperature, 0.7, accuracy: 0.0001)
        XCTAssertGreaterThan(chat.repeat_penalty, 1.0, "small models loop without a repetition penalty")
        XCTAssertGreaterThan(chat.repeat_last_n, 0)
        let defaults = try! XCTUnwrap(LlamaCppInferenceEngine.sampling(for: GenerationOptions(maxTokens: 256)))
        XCTAssertEqual(defaults.temperature, gus_llama_default_chat_sampling().temperature)
    }

    func testToolRoleIsFramedAsUser() {
        let mapped = LlamaCppInferenceEngine.chatMessages([
            ModelMessage(role: .system, content: "s"), ModelMessage(role: .tool, content: "t"),
            ModelMessage(role: .assistant, content: "a")
        ])
        XCTAssertEqual(mapped.map(\.role), ["system", "user", "assistant"])
    }
}
