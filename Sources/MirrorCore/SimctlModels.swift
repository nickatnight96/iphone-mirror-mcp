import Foundation

/// Models for `xcrun simctl list devices -j`.
public struct SimctlDeviceList: Decodable, Sendable {
    public struct Device: Decodable, Sendable {
        public let udid: String?
        public let name: String?
        public let state: String?
        public let isAvailable: Bool?
        public let deviceTypeIdentifier: String?
    }

    /// Keyed by runtime identifier, e.g. "com.apple.CoreSimulator.SimRuntime.iOS-26-4".
    public let devices: [String: [Device]]

    public static func parse(_ data: Data) throws -> SimctlDeviceList {
        do {
            return try JSONDecoder().decode(SimctlDeviceList.self, from: data)
        } catch {
            throw MirrorError("Could not parse simctl JSON output: \(error.localizedDescription)")
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-4" → "iOS 26.4"
    public static func prettyRuntime(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard parts.count > 1 else { return String(last) }
        return parts[0] + " " + parts.dropFirst().joined(separator: ".")
    }

    /// One line per available device, grouped by runtime, booted devices first
    /// within each runtime.
    public func describe(includeUnavailable: Bool = false) -> String {
        var lines: [String] = []
        for (runtime, deviceList) in devices.sorted(by: { $0.key < $1.key }) {
            let usable = deviceList.filter { includeUnavailable || ($0.isAvailable ?? false) }
            guard !usable.isEmpty else { continue }
            lines.append("[\(Self.prettyRuntime(runtime))]")
            let sorted = usable.sorted { a, b in
                let aBooted = a.state == "Booted", bBooted = b.state == "Booted"
                if aBooted != bBooted { return aBooted }
                return (a.name ?? "") < (b.name ?? "")
            }
            for device in sorted {
                lines.append("  \(device.name ?? "?") — \(device.state ?? "?"), udid=\(device.udid ?? "?")")
            }
        }
        return lines.isEmpty ? "No available simulators found." : lines.joined(separator: "\n")
    }
}
