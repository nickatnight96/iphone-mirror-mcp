import XCTest
@testable import MirrorCore

final class KeyTypingTests: XCTestCase {
    func testLowercaseLetters() {
        XCTAssertEqual(KeyTyping.key(for: "a"), TypedKey(keyCode: 0))
        XCTAssertEqual(KeyTyping.key(for: "z"), TypedKey(keyCode: 6))
    }

    func testUppercaseRequiresShift() {
        XCTAssertEqual(KeyTyping.key(for: "A"), TypedKey(keyCode: 0, shift: true))
        XCTAssertEqual(KeyTyping.key(for: "Q"), TypedKey(keyCode: 12, shift: true))
    }

    func testDigitsAndShiftedSymbols() {
        XCTAssertEqual(KeyTyping.key(for: "1"), TypedKey(keyCode: 18))
        XCTAssertEqual(KeyTyping.key(for: "!"), TypedKey(keyCode: 18, shift: true))
        XCTAssertEqual(KeyTyping.key(for: "@"), TypedKey(keyCode: 19, shift: true))
        XCTAssertEqual(KeyTyping.key(for: "?"), TypedKey(keyCode: 44, shift: true))
        XCTAssertEqual(KeyTyping.key(for: "\""), TypedKey(keyCode: 39, shift: true))
    }

    func testWhitespaceAndNewline() {
        XCTAssertEqual(KeyTyping.key(for: " "), TypedKey(keyCode: 49))
        XCTAssertEqual(KeyTyping.key(for: "\n"), TypedKey(keyCode: 36))
        XCTAssertEqual(KeyTyping.key(for: "\t"), TypedKey(keyCode: 48))
    }

    func testUntypeableCharacters() {
        XCTAssertNil(KeyTyping.key(for: "é"))
        XCTAssertNil(KeyTyping.key(for: "🎉"))
        XCTAssertNil(KeyTyping.key(for: "中"))
    }

    func testSegmentationGroupsRuns() {
        let segments = KeyTyping.segments(for: "hi🎉ok")
        XCTAssertEqual(segments, [
            KeyTyping.Segment(text: "hi", typeable: true),
            KeyTyping.Segment(text: "🎉", typeable: false),
            KeyTyping.Segment(text: "ok", typeable: true),
        ])
    }

    func testSegmentationAllTypeable() {
        let segments = KeyTyping.segments(for: "Hello, World! 123")
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].typeable)
    }

    func testSegmentationEmpty() {
        XCTAssertTrue(KeyTyping.segments(for: "").isEmpty)
    }

    func testEveryPrintableASCIICharacterIsTypeable() {
        for scalar in 32...126 {
            let char = Character(UnicodeScalar(scalar)!)
            XCTAssertNotNil(KeyTyping.key(for: char), "no mapping for '\(char)' (\(scalar))")
        }
    }
}
