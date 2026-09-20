import XCTest
@testable import OpencodeNativeCore

final class RemotePairingTests: XCTestCase {
    func testParsesPairingLink() throws {
        let link = "opencodenative://pair?host=192.168.1.5&port=4096&username=opencode&password=secret&directory=C%3A%5CDev%5CRepo"
        let pairing = try OpenCodePairing.parse(link)
        XCTAssertEqual(pairing.host, "192.168.1.5")
        XCTAssertEqual(pairing.scheme, "http")
        XCTAssertEqual(pairing.port, 4096)
        XCTAssertEqual(pairing.username, "opencode")
        XCTAssertEqual(pairing.password, "secret")
        XCTAssertEqual(pairing.directory, "C:\\Dev\\Repo")
    }

    func testRejectsWrongScheme() {
        XCTAssertThrowsError(try OpenCodePairing.parse("https://192.168.1.5:4096"))
    }

    func testDefaultsUsernameAndDirectory() throws {
        let pairing = try OpenCodePairing.parse("opencodenative://pair?host=10.0.0.2&port=4096&password=x")
        XCTAssertEqual(pairing.username, "opencode")
        XCTAssertEqual(pairing.directory, "")
    }

    func testSupportsSecurePairingLinks() throws {
        let pairing = try OpenCodePairing.parse("opencodenative://pair?scheme=https&host=danny.tail379054.ts.net&port=443&password=x")
        XCTAssertEqual(pairing.scheme, "https")
        XCTAssertEqual(pairing.baseURL.absoluteString, "https://danny.tail379054.ts.net:443")
    }

    func testRejectsUnknownTransportScheme() {
        XCTAssertThrowsError(try OpenCodePairing.parse("opencodenative://pair?scheme=ftp&host=example.test&port=4096&password=x"))
    }
}
