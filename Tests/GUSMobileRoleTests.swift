import XCTest
@testable import IysCodeMovilCore

final class GUSMobileRoleTests: XCTestCase {
    func testRoleStatesActualHarnessBoundaryAndUntrustedDataRule() {
        let prompt = GUSMobileRole.mobile.systemPrompt
        XCTAssertTrue(prompt.contains("capacidades que la app registra"))
        XCTAssertTrue(prompt.contains("shell, procesos, red arbitraria"))
        XCTAssertTrue(prompt.contains("datos no confiables"))
        XCTAssertTrue(prompt.contains("no afirmes que ejecutaste"))
    }

    func testRoleDoesNotGrantApprovalOrNewCapabilities() {
        let prompt = GUSMobileRole.mobile.systemPrompt.lowercased()
        XCTAssertTrue(prompt.contains("espera la aprobación"))
        XCTAssertFalse(prompt.contains("siempre tienes permiso"))
        XCTAssertFalse(prompt.contains("ignora las aprobaciones"))
    }
}
