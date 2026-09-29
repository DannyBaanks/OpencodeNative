import XCTest
@testable import IysCodeMovilCore

final class SessionApprovalTests: XCTestCase {
    func testMatchingOneTimeApprovalIsAccepted() {
        XCTAssertEqual(
            PermissionDecisionGate.decision(requestID: "request-1", pendingRequestID: "request-1", proposed: .allowOnce),
            .allowOnce
        )
    }

    func testMismatchedOrMissingRequestFailsClosed() {
        XCTAssertEqual(
            PermissionDecisionGate.decision(requestID: "stale", pendingRequestID: "current", proposed: .allowOnce),
            .deny
        )
        XCTAssertEqual(
            PermissionDecisionGate.decision(requestID: "request-1", pendingRequestID: nil, proposed: .allowOnce),
            .deny
        )
    }
}
