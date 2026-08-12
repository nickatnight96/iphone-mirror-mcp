import XCTest
@testable import MirrorCore

final class KeyMapTests: XCTestCase {
    func testNamedKeys() throws {
        XCTAssertEqual(try KeyMap.chord(from: "return"), KeyChord(keyCode: 36))
        XCTAssertEqual(try KeyMap.chord(from: "enter"), KeyChord(keyCode: 36))
        XCTAssertEqual(try KeyMap.chord(from: "escape"), KeyChord(keyCode: 53))
        XCTAssertEqual(try KeyMap.chord(from: "delete"), KeyChord(keyCode: 51))
        XCTAssertEqual(try KeyMap.chord(from: "up"), KeyChord(keyCode: 126))
    }

    func testMirroringShortcuts() throws {
        // The iPhone Mirroring app's own shortcuts.
        XCTAssertEqual(try KeyMap.chord(from: "cmd+1"), KeyChord(keyCode: 18, modifiers: .command))
        XCTAssertEqual(try KeyMap.chord(from: "cmd+2"), KeyChord(keyCode: 19, modifiers: .command))
        XCTAssertEqual(try KeyMap.chord(from: "cmd+3"), KeyChord(keyCode: 20, modifiers: .command))
    }

    func testMultipleModifiersAndAliases() throws {
        XCTAssertEqual(
            try KeyMap.chord(from: "Command+Shift+3"),
            KeyChord(keyCode: 20, modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            try KeyMap.chord(from: "ctrl+opt+a"),
            KeyChord(keyCode: 0, modifiers: [.control, .option])
        )
        XCTAssertEqual(
            try KeyMap.chord(from: "meta+space"),
            KeyChord(keyCode: 49, modifiers: .command)
        )
    }

    func testFunctionModifier() throws {
        XCTAssertEqual(
            try KeyMap.chord(from: "fn+left"),
            KeyChord(keyCode: 123, modifiers: .function)
        )
    }

    func testSingleCharacterKeys() throws {
        XCTAssertEqual(try KeyMap.chord(from: "a"), KeyChord(keyCode: 0))
        XCTAssertEqual(try KeyMap.chord(from: "/"), KeyChord(keyCode: 44))
    }

    func testInvalidSpecsThrow() {
        XCTAssertThrowsError(try KeyMap.chord(from: "cmd+"))
        XCTAssertThrowsError(try KeyMap.chord(from: ""))
        XCTAssertThrowsError(try KeyMap.chord(from: "cmd+ß"))
        XCTAssertThrowsError(try KeyMap.chord(from: "bogus+a"))
        XCTAssertThrowsError(try KeyMap.chord(from: "notakey"))
    }
}
