import Foundation

/// Wrappers around xcodebuild, devicectl, and simctl. All invocations go
/// through ProcessRunner with argument arrays — no shell interpolation.
public enum XcodeTools {
    static let xcrun = "/usr/bin/xcrun"
    static let xcodebuild = "/usr/bin/xcodebuild"

    /// Adds -project/-workspace arguments from a path. `.xcworkspace` →
    /// -workspace, `.xcodeproj` → -project; a bare directory is left to
    /// xcodebuild's auto-discovery (Package.swift or single project).
    static func containerArguments(projectPath: String?) -> [String] {
        guard let projectPath else { return [] }
        if projectPath.hasSuffix(".xcworkspace") { return ["-workspace", projectPath] }
        if projectPath.hasSuffix(".xcodeproj") { return ["-project", projectPath] }
        return []
    }

    static func workingDirectory(projectPath: String?) -> String? {
        guard let projectPath else { return nil }
        if projectPath.hasSuffix(".xcworkspace") || projectPath.hasSuffix(".xcodeproj") {
            return (projectPath as NSString).deletingLastPathComponent
        }
        return projectPath
    }

    // MARK: - xcodebuild

    /// `xcodebuild -list -json`: schemes, targets, configurations.
    public static func list(projectPath: String?) async throws -> String {
        let result = try await ProcessRunner.run(
            xcodebuild, ["-list", "-json"] + containerArguments(projectPath: projectPath),
            currentDirectory: workingDirectory(projectPath: projectPath),
            timeout: 60
        )
        guard result.succeeded else {
            throw MirrorError("xcodebuild -list failed (exit \(result.exitCode)): \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
        return result.stdout
    }

    public struct BuildRequest: Sendable {
        public var projectPath: String?
        public var scheme: String
        public var configuration: String?
        public var destination: String?
        public var derivedDataPath: String?
        public var allowProvisioningUpdates: Bool
        public var extraArguments: [String]
        public var timeoutSeconds: Int
        /// When set, xcodebuild writes an .xcresult bundle here (test runs) —
        /// attachments/screenshots can then be exported from it.
        public var resultBundlePath: String?

        public init(
            projectPath: String? = nil, scheme: String, configuration: String? = nil,
            destination: String? = nil, derivedDataPath: String? = nil,
            allowProvisioningUpdates: Bool = true, extraArguments: [String] = [],
            timeoutSeconds: Int = 900
        ) {
            self.projectPath = projectPath
            self.scheme = scheme
            self.configuration = configuration
            self.destination = destination
            self.derivedDataPath = derivedDataPath
            self.allowProvisioningUpdates = allowProvisioningUpdates
            self.extraArguments = extraArguments
            self.timeoutSeconds = timeoutSeconds
        }

        func arguments(action: [String]) -> [String] {
            var args = XcodeTools.containerArguments(projectPath: projectPath)
            args += ["-scheme", scheme]
            if let configuration { args += ["-configuration", configuration] }
            if let destination { args += ["-destination", destination] }
            if let derivedDataPath { args += ["-derivedDataPath", derivedDataPath] }
            if let resultBundlePath { args += ["-resultBundlePath", resultBundlePath] }
            if allowProvisioningUpdates { args.append("-allowProvisioningUpdates") }
            args += extraArguments
            args += action
            return args
        }
    }

    public struct BuildOutcome: Sendable {
        public let summary: XcodebuildSummary
        public let exitCode: Int32
        public let timedOut: Bool
        public let rawTail: String

        public var description: String {
            var text = XcodebuildOutputParser.describe(summary, exitCode: exitCode, timedOut: timedOut)
            // A failed run with no parsed error lines (e.g. the "error:" lines
            // fell inside the truncation gap of a huge log) would otherwise be
            // actionless — attach the raw tail so the caller sees something.
            if summary.errors.isEmpty && (summary.outcome == .unknown || exitCode != 0 || timedOut) {
                text += "\n--- output tail ---\n" + rawTail.suffix(2000)
            }
            return text
        }
        public var succeeded: Bool {
            !timedOut && exitCode == 0
        }
    }

    static func runXcodebuild(_ request: BuildRequest, action: [String]) async throws -> BuildOutcome {
        let result = try await ProcessRunner.run(
            xcodebuild, request.arguments(action: action),
            currentDirectory: workingDirectory(projectPath: request.projectPath),
            timeout: TimeInterval(min(max(request.timeoutSeconds, 30), 3600))
        )
        let combined = result.stdout + "\n" + result.stderr
        return BuildOutcome(
            summary: XcodebuildOutputParser.parse(combined),
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            rawTail: String(combined.suffix(4000))
        )
    }

    public static func build(_ request: BuildRequest) async throws -> BuildOutcome {
        try await runXcodebuild(request, action: ["build"])
    }

    public static func test(_ request: BuildRequest, onlyTesting: [String] = []) async throws -> BuildOutcome {
        try await runXcodebuild(request, action: onlyTesting.map { "-only-testing:\($0)" } + ["test"])
    }

    /// Finds the built .app bundle inside derived data for a configuration.
    /// `platformSuffix` is "iphoneos" for device builds, "iphonesimulator"
    /// for simulator builds.
    public static func builtAppPath(
        derivedDataPath: String, configuration: String, platformSuffix: String = "iphoneos"
    ) throws -> String {
        let productsDir = derivedDataPath + "/Build/Products/\(configuration)-\(platformSuffix)"
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: productsDir)) ?? []
        guard let app = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw MirrorError(
                "No .app found in \(productsDir).",
                remediation: "Confirm the scheme builds an iOS app target and the build succeeded.")
        }
        return productsDir + "/" + app
    }

    /// Reads CFBundleIdentifier from an .app bundle.
    public static func bundleIdentifier(ofApp appPath: String) throws -> String {
        let plistPath = appPath + "/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else {
            throw MirrorError("Could not read CFBundleIdentifier from \(plistPath).")
        }
        return bundleID
    }

    // MARK: - devicectl (physical devices)

    /// `devicectl list devices` parsed from its JSON output file.
    public static func physicalDevices() async throws -> [DevicectlDeviceList.Device] {
        // Unique per call: concurrent tool calls in this one server process
        // must not share (and defer-delete) the same temp file.
        let jsonPath = NSTemporaryDirectory() + "iphone-mirror-mcp-devices-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: jsonPath) }
        let result = try await ProcessRunner.run(
            xcrun, ["devicectl", "list", "devices", "--json-output", jsonPath], timeout: 60)
        guard result.exitCode == 0, let data = FileManager.default.contents(atPath: jsonPath) else {
            throw MirrorError("devicectl list devices failed (exit \(result.exitCode)): \(result.stderr)")
        }
        return try DevicectlDeviceList.parse(data)
    }

    /// Resolves a device query (name, udid, or identifier; nil = first iPhone)
    /// to a devicectl-usable identifier.
    public static func resolveDevice(_ query: String?) async throws -> (identifier: String, name: String) {
        let devices = try await physicalDevices()
        guard !devices.isEmpty else {
            throw MirrorError(
                "No physical iOS devices are paired with this Mac.",
                remediation: "Pair the iPhone in Xcode (Window → Devices and Simulators) and trust this computer on the phone.")
        }
        func identity(_ device: DevicectlDeviceList.Device) -> (String, String)? {
            guard let id = device.hardwareProperties?.udid ?? device.identifier else { return nil }
            return (id, device.deviceProperties?.name ?? id)
        }
        guard let query else {
            guard let first = devices.compactMap(identity).first else {
                throw MirrorError("Paired devices found, but none reported a usable identifier.")
            }
            return first
        }
        let lowered = query.lowercased()
        for device in devices {
            let candidates = [
                device.hardwareProperties?.udid, device.identifier, device.deviceProperties?.name,
            ].compactMap { $0?.lowercased() }
            if candidates.contains(lowered), let id = identity(device) { return id }
        }
        throw MirrorError(
            "No paired device matched \"\(query)\".",
            remediation: "Use the devices tool to list valid names/udids.")
    }

    public static func deviceInstall(device: String, appPath: String) async throws -> String {
        let result = try await ProcessRunner.run(
            xcrun, ["devicectl", "device", "install", "app", "--device", device, appPath],
            timeout: 300)
        guard result.exitCode == 0 else {
            throw MirrorError("devicectl install failed (exit \(result.exitCode)): \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
        return result.stdout
    }

    /// Launches an app on a physical device. With `consoleSeconds > 0`, the
    /// launch attaches the console and captures output for that long (the
    /// process is then detached by our watchdog — the app keeps running).
    public static func deviceLaunch(
        device: String, bundleID: String, terminateExisting: Bool, consoleSeconds: Int
    ) async throws -> String {
        var args = ["devicectl", "device", "process", "launch", "--device", device]
        if terminateExisting { args.append("--terminate-existing") }
        if consoleSeconds > 0 { args.append("--console") }
        args.append(bundleID)
        let timeout: TimeInterval = consoleSeconds > 0 ? TimeInterval(min(consoleSeconds, 300)) : 60
        let result = try await ProcessRunner.run(xcrun, args, timeout: timeout)
        if consoleSeconds > 0 && result.timedOut {
            return "Launched \(bundleID); console captured for \(Int(timeout))s:\n" + result.stdout
        }
        guard result.exitCode == 0 else {
            throw MirrorError("devicectl launch failed (exit \(result.exitCode)): \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
        return result.stdout.isEmpty ? "Launched \(bundleID)." : result.stdout
    }

    // MARK: - simctl (simulators)

    public static func simulators() async throws -> SimctlDeviceList {
        let result = try await ProcessRunner.run(xcrun, ["simctl", "list", "devices", "-j"], timeout: 60)
        guard result.exitCode == 0 else {
            throw MirrorError("simctl list failed (exit \(result.exitCode)): \(result.stderr)")
        }
        return try SimctlDeviceList.parse(Data(result.stdout.utf8))
    }

    /// Resolves a simulator query (udid or name; nil = the booted one).
    public static func resolveSimulator(_ query: String?) async throws -> (udid: String, name: String) {
        let list = try await simulators()
        let all = list.devices.values.flatMap { $0 }.filter { $0.isAvailable ?? false }
        if let query {
            let lowered = query.lowercased()
            if let match = all.first(where: {
                $0.udid?.lowercased() == lowered || $0.name?.lowercased() == lowered
            }), let udid = match.udid {
                return (udid, match.name ?? udid)
            }
            throw MirrorError("No available simulator matched \"\(query)\". Use the devices tool to list them.")
        }
        if let booted = all.first(where: { $0.state == "Booted" }), let udid = booted.udid {
            return (udid, booted.name ?? udid)
        }
        throw MirrorError(
            "No simulator is booted.",
            remediation: "Pass a simulator name/udid, or boot one with the sim_boot tool.")
    }

    @discardableResult
    public static func simctl(_ arguments: [String], timeout: TimeInterval = 120) async throws -> String {
        let result = try await ProcessRunner.run(xcrun, ["simctl"] + arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw MirrorError("simctl \(arguments.first ?? "") failed (exit \(result.exitCode)): \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
        return result.stdout
    }

    // MARK: - Build & run on the mirrored iPhone

    public struct RunOnDeviceOutcome: Sendable {
        public let deviceName: String
        public let appPath: String
        public let bundleID: String
        public let buildDescription: String
        public let launchOutput: String
    }

    /// The flagship pipeline: build for the paired iPhone, install via
    /// devicectl, launch — after which the app is on the mirrored screen and
    /// can be driven with the tap/swipe/OCR tools.
    public static func buildAndRunOnDevice(
        projectPath: String?, scheme: String, configuration: String,
        device: String?, timeoutSeconds: Int
    ) async throws -> RunOnDeviceOutcome {
        let (identifier, name) = try await resolveDevice(device)

        let derivedData = (workingDirectory(projectPath: projectPath) ?? NSTemporaryDirectory())
            + "/.iphone-mirror-mcp-derived"
        var request = BuildRequest(
            projectPath: projectPath, scheme: scheme, configuration: configuration,
            destination: "platform=iOS,id=\(identifier)",
            derivedDataPath: derivedData,
            timeoutSeconds: timeoutSeconds
        )
        request.allowProvisioningUpdates = true
        let build = try await build(request)
        guard build.succeeded else {
            throw MirrorError("Build failed:\n\(build.description)")
        }

        let appPath = try builtAppPath(derivedDataPath: derivedData, configuration: configuration)
        let bundleID = try bundleIdentifier(ofApp: appPath)
        _ = try await deviceInstall(device: identifier, appPath: appPath)
        let launchOutput = try await deviceLaunch(
            device: identifier, bundleID: bundleID, terminateExisting: true, consoleSeconds: 0)

        return RunOnDeviceOutcome(
            deviceName: name, appPath: appPath, bundleID: bundleID,
            buildDescription: build.description, launchOutput: launchOutput
        )
    }

    // MARK: - Build & run on a simulator

    /// Resolves a simulator for a run: explicit name/udid among available
    /// sims; nil prefers the booted one, then the first available iPhone.
    public static func resolveSimulatorForRun(_ query: String?) async throws -> (udid: String, name: String, booted: Bool) {
        let list = try await simulators()
        let all = list.devices.values.flatMap { $0 }.filter { $0.isAvailable ?? false }
        if let query {
            let lowered = query.lowercased()
            guard let match = all.first(where: {
                $0.udid?.lowercased() == lowered || $0.name?.lowercased() == lowered
            }), let udid = match.udid else {
                throw MirrorError("No available simulator matched \"\(query)\". Use the devices tool to list them.")
            }
            return (udid, match.name ?? udid, match.state == "Booted")
        }
        if let booted = all.first(where: { $0.state == "Booted" }), let udid = booted.udid {
            return (udid, booted.name ?? udid, true)
        }
        guard let iphone = all.first(where: { ($0.name ?? "").contains("iPhone") }), let udid = iphone.udid else {
            throw MirrorError("No available iPhone simulator found.")
        }
        return (udid, iphone.name ?? udid, false)
    }

    /// The simulator twin of buildAndRunOnDevice: build for the simulator,
    /// boot it if needed, install, launch.
    public static func buildAndRunOnSimulator(
        projectPath: String?, scheme: String, configuration: String,
        simulator: String?, timeoutSeconds: Int
    ) async throws -> RunOnDeviceOutcome {
        let (udid, name, booted) = try await resolveSimulatorForRun(simulator)

        let derivedData = (workingDirectory(projectPath: projectPath) ?? NSTemporaryDirectory())
            + "/.iphone-mirror-mcp-derived"
        let request = BuildRequest(
            projectPath: projectPath, scheme: scheme, configuration: configuration,
            destination: "platform=iOS Simulator,id=\(udid)",
            derivedDataPath: derivedData,
            timeoutSeconds: timeoutSeconds
        )
        let build = try await build(request)
        guard build.succeeded else {
            throw MirrorError("Build failed:\n\(build.description)")
        }

        if !booted {
            do { _ = try await simctl(["boot", udid]) }
            catch let error as MirrorError where error.message.contains("state: Booted") {}
        }
        _ = try await ProcessRunner.run("/usr/bin/open", ["-a", "Simulator"], timeout: 30)

        let appPath = try builtAppPath(
            derivedDataPath: derivedData, configuration: configuration,
            platformSuffix: "iphonesimulator")
        let bundleID = try bundleIdentifier(ofApp: appPath)
        _ = try await simctl(["install", udid, appPath])
        let launchOutput = try await simctl(["launch", udid, bundleID])

        return RunOnDeviceOutcome(
            deviceName: name, appPath: appPath, bundleID: bundleID,
            buildDescription: build.description, launchOutput: launchOutput
        )
    }

    // MARK: - Logs & result bundles

    /// Arguments for reading a simulator's recent unified log.
    /// Pure so tests can pin the shape.
    public static func simLogShowArguments(
        udid: String, last: String, process: String?, predicate: String?
    ) -> [String] {
        var args = ["spawn", udid, "log", "show", "--last", last, "--style", "compact"]
        var predicates: [String] = []
        if let process { predicates.append("process == \"\(process)\"") }
        if let predicate { predicates.append("(\(predicate))") }
        if !predicates.isEmpty {
            args += ["--predicate", predicates.joined(separator: " AND ")]
        }
        return args
    }

    /// Recent unified-log entries from a simulator, optionally filtered to a
    /// process name and/or an NSPredicate. Output is tail-truncated.
    public static func simLog(
        simulator: String?, last: String, process: String?, predicate: String?, maxChars: Int = 20_000
    ) async throws -> String {
        let (udid, name) = try await resolveSimulator(simulator)
        let output = try await simctl(
            simLogShowArguments(udid: udid, last: last, process: process, predicate: predicate),
            timeout: 120)
        let trimmed = output.count > maxChars ? "…(truncated)…\n" + output.suffix(maxChars) : output
        return "Log of \(name) (last \(last)\(process.map { ", process \($0)" } ?? "")):\n\(trimmed)"
    }

    /// Exports every attachment (screenshots, txt, …) from an .xcresult
    /// bundle into a directory and returns the exported file paths.
    public static func exportAttachments(xcresultPath: String, outputDir: String?) async throws -> (dir: String, files: [String]) {
        guard FileManager.default.fileExists(atPath: xcresultPath) else {
            throw MirrorError("No .xcresult bundle at \(xcresultPath).",
                              remediation: "Run xcode_test first — its output includes the result bundle path.")
        }
        let dir = outputDir ?? NSTemporaryDirectory() + "xcresult-attachments-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run(
            xcrun, ["xcresulttool", "export", "attachments", "--path", xcresultPath, "--output-path", dir],
            timeout: 120)
        guard result.exitCode == 0 else {
            throw MirrorError("xcresulttool export failed (exit \(result.exitCode)): \(result.stderr)")
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        return (dir, files)
    }
}
