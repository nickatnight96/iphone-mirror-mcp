import AppKit
import Foundation

/// Snapshot/restore access to the general pasteboard.
///
/// iPhone Mirroring bridges the Mac pasteboard to the phone: ⌘V pastes the
/// Mac clipboard into the focused phone text field, and ⌘C in a mirrored app
/// lands the phone's copy on the Mac pasteboard. That makes the pasteboard
/// the ONLY full-fidelity text path to the phone — keystroke typing is
/// ASCII-only — but it is also the USER'S clipboard, so every write here
/// must restore what the user had.
public enum MacPasteboard {
    /// One captured pasteboard item: every type it carried, with data.
    public struct Item: Sendable {
        public let types: [(type: String, data: Data)]
    }

    /// Deep-copies the current pasteboard contents (NSPasteboardItem
    /// instances cannot outlive a clearContents, so raw data is captured).
    public static func snapshot() -> [Item] {
        let pasteboard = NSPasteboard.general
        return (pasteboard.pasteboardItems ?? []).map { item in
            Item(types: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
    }

    public static func setString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    public static func restore(_ items: [Item]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { captured in
            let item = NSPasteboardItem()
            for (type, data) in captured.types {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        })
    }

    public static func string() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// The general pasteboard's change count. Every write bumps it, so a
    /// copy that landed is a count that moved.
    public static func changeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    /// Polls until the change count moves away from `since` or the timeout
    /// elapses. Returns true when it moved. The bridged copy lands
    /// asynchronously; a fixed sleep either waits too long or reads the old
    /// Mac clipboard as if it came from the phone.
    public static func waitForChange(
        since: Int, timeout: TimeInterval, pollInterval: TimeInterval = 0.05,
        changeCount: () -> Int = { NSPasteboard.general.changeCount }
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if changeCount() != since { return true }
            if Date() >= deadline { return false }
            usleep(UInt32(pollInterval * 1_000_000))
        }
    }
}
