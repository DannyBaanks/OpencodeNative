import XCTest
@testable import OpencodeNativeCore

final class GlobMatcherTests: XCTestCase {
    func testSimpleStarExtension() {
        XCTAssertTrue(GlobMatcher.match("*.swift", "main.swift"))
        XCTAssertFalse(GlobMatcher.match("*.swift", "main.txt"))
    }

    func testAsteriskDoesNotCrossSlash() {
        // `*` matches everything except `/`
        XCTAssertTrue(GlobMatcher.match("*.txt", "notes.txt"))
        XCTAssertFalse(GlobMatcher.match("*.txt", "a/b.txt"))
    }

    func testDoubleStarAcrossDirs() {
        XCTAssertTrue(GlobMatcher.match("**/*.swift", "main.swift"))
        XCTAssertTrue(GlobMatcher.match("**/*.swift", "src/main.swift"))
        XCTAssertTrue(GlobMatcher.match("**/*.swift", "a/b/c/main.swift"))
        XCTAssertFalse(GlobMatcher.match("**/*.swift", "main.txt"))
    }

    func testQuestionMark() {
        XCTAssertTrue(GlobMatcher.match("?.txt", "a.txt"))
        XCTAssertFalse(GlobMatcher.match("?.txt", "ab.txt"))
        XCTAssertFalse(GlobMatcher.match("?.txt", "/a.txt"))
    }

    func testExactMatch() {
        XCTAssertTrue(GlobMatcher.match("notes.txt", "notes.txt"))
        XCTAssertFalse(GlobMatcher.match("notes.txt", "notes2.txt"))
    }

    func testLiteralDotIsNotWildcard() {
        XCTAssertFalse(GlobMatcher.match("a.swift", "abswift"))
    }

    func testPatternToRegexAnchored() {
        XCTAssertEqual(GlobMatcher.patternToRegex("*.swift"), "^[^/]*\\.swift$")
    }
}
