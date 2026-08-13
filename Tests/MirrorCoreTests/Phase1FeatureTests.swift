import XCTest
@testable import MirrorCore

/// Phase-1 feature units: sim log argument shape, simulator build products,
/// and the doctor report format.
final class Phase1FeatureTests: XCTestCase {
    func testSimLogArgumentsBareAndFiltered() {
        XCTAssertEqual(
            XcodeTools.simLogShowArguments(udid: "U", last: "2m", process: nil, predicate: nil),
            ["spawn", "U", "log", "show", "--last", "2m", "--style", "compact"])

        let filtered = XcodeTools.simLogShowArguments(
            udid: "U", last: "30s", process: "MyApp", predicate: "eventMessage contains \"x\"")
        XCTAssertEqual(filtered.suffix(2).first, "--predicate")
        XCTAssertEqual(filtered.last, "process == \"MyApp\" AND (eventMessage contains \"x\")")
    }

    func testBuiltAppPathHonorsPlatformSuffix() throws {
        let root = NSTemporaryDirectory() + "phase1-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let simProducts = root + "/Build/Products/Debug-iphonesimulator"
        try FileManager.default.createDirectory(
            atPath: simProducts + "/Demo.app", withIntermediateDirectories: true)

        let found = try XcodeTools.builtAppPath(
            derivedDataPath: root, configuration: "Debug", platformSuffix: "iphonesimulator")
        XCTAssertTrue(found.hasSuffix("Debug-iphonesimulator/Demo.app"))

        // The device suffix must NOT find the simulator build.
        XCTAssertThrowsError(try XcodeTools.builtAppPath(
            derivedDataPath: root, configuration: "Debug"))
    }

    func testResultBundlePathAppearsInXcodebuildArguments() {
        var request = XcodeTools.BuildRequest(scheme: "S")
        request.resultBundlePath = "/tmp/r.xcresult"
        let arguments = request.arguments(action: ["test"])
        let index = arguments.firstIndex(of: "-resultBundlePath")
        XCTAssertNotNil(index)
        XCTAssertEqual(arguments[arguments.index(after: index!)], "/tmp/r.xcresult")
    }

    func testDoctorReportFormatsAllStates() {
        var report = MirrorSession.DoctorReport()
        report.accessibility = true
        report.screenRecording = true
        report.postEventAccess = false
        report.automation = nil
        report.sessionState = "connected"
        report.windowLine = "id=42"
        report.captureLine = "[PASS] Capture: 696x1532 px in 0.20s"
        report.inputDeliveryLine = "[FAIL] Input delivery: nope"

        let text = report.describe()
        XCTAssertTrue(text.contains("[PASS] Accessibility"))
        XCTAssertTrue(text.contains("[PASS] Screen Recording"))
        XCTAssertTrue(text.contains("[FAIL] Post-event access"))
        XCTAssertTrue(text.contains("[????] Automation"))
        XCTAssertTrue(text.contains("Session: connected"))
        XCTAssertTrue(text.contains("[FAIL] Input delivery"))

        report.automation = false
        XCTAssertTrue(report.describe().contains("[FAIL] Automation"))
        report.automation = true
        XCTAssertTrue(report.describe().contains("[PASS] Automation"))
    }
}
