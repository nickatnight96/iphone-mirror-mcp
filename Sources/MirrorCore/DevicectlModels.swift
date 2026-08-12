import Foundation

/// Tolerant models for `xcrun devicectl list devices --json-output`.
/// Every field is optional: devicectl's schema shifts between Xcode releases,
/// and a missing property must never make the whole listing fail.
public struct DevicectlDeviceList: Decodable, Sendable {
    public struct Result: Decodable, Sendable {
        public let devices: [Device]?
    }

    public struct Device: Decodable, Sendable {
        public struct DeviceProperties: Decodable, Sendable {
            public let name: String?
            public let osVersionNumber: String?
            public let bootState: String?
        }
        public struct HardwareProperties: Decodable, Sendable {
            public let udid: String?
            public let marketingName: String?
            public let platform: String?
            public let deviceType: String?
        }
        public struct ConnectionProperties: Decodable, Sendable {
            public let transportType: String?
            public let tunnelState: String?
            public let pairingState: String?
        }

        public let identifier: String?
        public let deviceProperties: DeviceProperties?
        public let hardwareProperties: HardwareProperties?
        public let connectionProperties: ConnectionProperties?
    }

    public let result: Result?

    public static func parse(_ data: Data) throws -> [Device] {
        do {
            let list = try JSONDecoder().decode(DevicectlDeviceList.self, from: data)
            return list.result?.devices ?? []
        } catch {
            throw MirrorError("Could not parse devicectl JSON output: \(error.localizedDescription)")
        }
    }

    /// One line per device: name, model, OS, udid, connection state.
    public static func describe(_ devices: [Device]) -> String {
        guard !devices.isEmpty else {
            return "No physical devices are paired. Pair an iPhone/iPad in Xcode (Window → Devices and Simulators) or check the cable/Wi-Fi connection."
        }
        return devices.map { device in
            let name = device.deviceProperties?.name ?? "?"
            let model = device.hardwareProperties?.marketingName ?? device.hardwareProperties?.deviceType ?? "?"
            let os = device.deviceProperties?.osVersionNumber ?? "?"
            let udid = device.hardwareProperties?.udid ?? device.identifier ?? "?"
            let transport = device.connectionProperties?.transportType ?? "?"
            let tunnel = device.connectionProperties?.tunnelState ?? "?"
            return "\(name) — \(model), iOS \(os), udid=\(udid), transport=\(transport), tunnel=\(tunnel)"
        }.joined(separator: "\n")
    }
}
