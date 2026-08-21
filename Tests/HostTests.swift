import XCTest
@testable import OpencodeNativeCore

final class CapabilityMatrixTests: XCTestCase {
    func testProbeOnNonIOSHostIsNotApplicable() {
        let matrix = IOSCapabilityMatrix.probeCurrent()
        // En un runner de tests no-iOS, todas las capabilities deben ser `notApplicable`.
        if !matrix.isIOS {
            XCTAssertEqual(matrix.sandboxFS.availability, .notApplicable)
            XCTAssertEqual(matrix.processExec.availability, .notApplicable)
            XCTAssertEqual(matrix.ptyTTY.availability, .notApplicable)
            XCTAssertEqual(matrix.networkTLS.availability, .notApplicable)
        }
    }
}

final class CompatibilityReportTests: XCTestCase {
    func testNonIOSReportIsUnchartedAndNoFalseBlockAlert() {
        let matrix = IOSCapabilityMatrix.probeCurrent()
        let report = CompatibilityReport.generate(from: matrix)
        if !matrix.isIOS {
            XCTAssertEqual(report.entries.count, OpenCodeRuntimeContract.Requirement.allCases.count)
            // En host no-iOS no se debe afirmar ni compatibilidad ni bloqueo concreto.
            XCTAssertTrue(report.entries.allSatisfy { $0.verdict == .uncharted })
            XCTAssertNil(report.firstBlocker) // no .unsupported -> no false blocker claim
        }
    }

    func testContractAllRequirementsHaveEvidence() {
        for req in OpenCodeRuntimeContract.Requirement.allCases {
            XCTAssertFalse(req.evidence.isEmpty, "\(req.rawValue) sin evidence")
            XCTAssertFalse(req.label.isEmpty)
        }
    }

    func testRenderTextNonEmptyOnNonIOS() {
        let matrix = IOSCapabilityMatrix.probeCurrent()
        let report = CompatibilityReport.generate(from: matrix)
        let text = report.renderText()
        XCTAssertTrue(text.contains("OpenCode TUI Compatibility"))
        for req in OpenCodeRuntimeContract.Requirement.allCases {
            XCTAssertTrue(text.contains(req.label), "renderText falta \(req.label)")
        }
    }
}

final class OpenCodeBootAttemptTests: XCTestCase {
    func testBootAttemptReturnsTranscript() {
        let attempt = OpenCodeBootAttempt.run()
        XCTAssertFalse(attempt.transcript.isEmpty)
        XCTAssertTrue(attempt.transcript.contains { $0.contains("OpenCode TUI") })
        XCTAssertEqual(attempt.host, IOSCapabilityMatrix.probeCurrent().platform)
    }
}
