import XCTest
@testable import MirrorCore

final class SimctlModelsTests: XCTestCase {
    let sampleJSON = """
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
          { "udid": "AAA", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true },
          { "udid": "BBB", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true },
          { "udid": "CCC", "name": "Broken", "state": "Shutdown", "isAvailable": false }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-18-0": []
      }
    }
    """

    func testPrettyRuntime() {
        XCTAssertEqual(
            SimctlDeviceList.prettyRuntime("com.apple.CoreSimulator.SimRuntime.iOS-26-4"),
            "iOS 26.4"
        )
        XCTAssertEqual(
            SimctlDeviceList.prettyRuntime("com.apple.CoreSimulator.SimRuntime.watchOS-11-2"),
            "watchOS 11.2"
        )
    }

    func testDescribeFiltersUnavailableAndSortsBootedFirst() throws {
        let list = try SimctlDeviceList.parse(Data(sampleJSON.utf8))
        let text = list.describe()
        XCTAssertTrue(text.contains("[iOS 26.4]"))
        XCTAssertFalse(text.contains("Broken"))
        let bootedIndex = text.range(of: "iPhone 17 Pro")!.lowerBound
        let shutdownIndex = text.range(of: "iPhone 17 —")!.lowerBound
        XCTAssertLessThan(bootedIndex, shutdownIndex)
    }

    func testGarbageThrowsMirrorError() {
        XCTAssertThrowsError(try SimctlDeviceList.parse(Data("[]".utf8))) { error in
            XCTAssertTrue(error is MirrorError)
        }
    }
}
