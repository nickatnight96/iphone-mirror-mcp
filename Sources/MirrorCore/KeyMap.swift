import CoreGraphics
import Foundation

/// A resolved key press: a virtual keycode plus modifier flags.
public struct KeyChord: Equatable, Sendable {
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)
    }

    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Parses human-readable key specs like "return", "cmd+1", "cmd+shift+3",
/// "ctrl+space" into virtual keycodes (ANSI US layout).
public enum KeyMap {
    static let namedKeys: [String: UInt16] = [
        "return": 36, "enter": 36,
        "tab": 48,
        "space": 49,
        "delete": 51, "backspace": 51,
        "forwarddelete": 117,
        "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static let characterKeys: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    static let modifierAliases: [String: KeyChord.Modifiers] = [
        "cmd": .command, "command": .command, "meta": .command,
        "shift": .shift,
        "opt": .option, "option": .option, "alt": .option,
        "ctrl": .control, "control": .control,
        "fn": .function, "function": .function,
    ]

    /// Parses a spec like "cmd+shift+3" or "return". The final "+"-separated
    /// token is the key; every preceding token must be a modifier.
    public static func chord(from spec: String) throws -> KeyChord {
        let tokens = spec.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let keyToken = tokens.last, !keyToken.isEmpty else {
            throw MirrorError("Empty key in key spec \"\(spec)\".",
                              remediation: "Use a spec like \"return\", \"cmd+1\", or \"cmd+shift+3\".")
        }
        var modifiers: KeyChord.Modifiers = []
        for token in tokens.dropLast() {
            guard let modifier = modifierAliases[token] else {
                throw MirrorError("Unknown modifier \"\(token)\" in key spec \"\(spec)\".",
                                  remediation: "Valid modifiers: cmd, shift, opt, ctrl, fn.")
            }
            modifiers.insert(modifier)
        }
        if let code = namedKeys[keyToken] {
            return KeyChord(keyCode: code, modifiers: modifiers)
        }
        if keyToken.count == 1, let code = characterKeys[keyToken.first!] {
            return KeyChord(keyCode: code, modifiers: modifiers)
        }
        throw MirrorError("Unknown key \"\(keyToken)\" in key spec \"\(spec)\".",
                          remediation: "Use a named key (return, tab, space, delete, escape, arrows, home, end, pageup, pagedown, f1-f12) or a single ASCII character.")
    }
}
