import CoreGraphics
import Foundation

/// A single key press that produces one character: virtual keycode plus
/// whether shift must be held.
public struct TypedKey: Equatable, Sendable {
    public let keyCode: UInt16
    public let shift: Bool
    public init(keyCode: UInt16, shift: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
    }
}

/// Maps characters to US-QWERTY key presses for CGEvent typing.
///
/// iPhone Mirroring only honors HID-style key events (it ignores
/// unicode-string keyboard events), so text must be typed key by key.
/// Characters outside this table (emoji, CJK, accented letters) cannot be
/// typed and are reported back to the caller as skipped.
public enum KeyTyping {
    /// Shifted-symbol → base-key character (US QWERTY).
    static let shiftedSymbols: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
        "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
        ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// Resolves a character to a key press, or nil when untypeable.
    public static func key(for character: Character) -> TypedKey? {
        switch character {
        case "\n", "\r": return TypedKey(keyCode: 36)
        case "\t": return TypedKey(keyCode: 48)
        case " ": return TypedKey(keyCode: 49)
        default: break
        }
        if character.isUppercase, let lower = character.lowercased().first,
           let code = KeyMap.characterKeys[lower] {
            return TypedKey(keyCode: code, shift: true)
        }
        if let base = shiftedSymbols[character], let code = KeyMap.characterKeys[base] {
            return TypedKey(keyCode: code, shift: true)
        }
        if let code = KeyMap.characterKeys[character] {
            return TypedKey(keyCode: code)
        }
        return nil
    }

    public struct Segment: Equatable, Sendable {
        public let text: String
        public let typeable: Bool
    }

    /// Splits text into runs of typeable vs untypeable characters so the
    /// caller can type what it can and report the rest.
    public static func segments(for text: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var currentTypeable: Bool?
        for character in text {
            let typeable = key(for: character) != nil
            if typeable == currentTypeable {
                current.append(character)
            } else {
                if let t = currentTypeable, !current.isEmpty {
                    segments.append(Segment(text: current, typeable: t))
                }
                current = String(character)
                currentTypeable = typeable
            }
        }
        if let t = currentTypeable, !current.isEmpty {
            segments.append(Segment(text: current, typeable: t))
        }
        return segments
    }
}
