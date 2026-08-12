import XCTest
@testable import MirrorCore

final class DevicectlModelsTests: XCTestCase {
    let sampleJSON = """
    {
      "info": { "outcome": "success" },
      "result": {
        "devices": [
          {
            "identifier": "D57789CA-7D58-5D6F-9625-53FB869C98D3",
            "connectionProperties": {
              "pairingState": "paired",
              "transportType": "wired",
              "tunnelState": "connected"
            },
            "deviceProperties": {
              "name": "iPhone",
              "osVersionNumber": "26.5"
            },
            "hardwareProperties": {
              "udid": "00008130-000A1234567890AB",
              "marketingName": "iPhone 15 Pro Max",
              "platform": "iOS",
              "deviceType": "iPhone16,2"
            }
          }
        ]
      }
    }
    """

    func testParseAndDescribe() throws {
        let devices = try DevicectlDeviceList.parse(Data(sampleJSON.utf8))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].deviceProperties?.name, "iPhone")
        XCTAssertEqual(devices[0].hardwareProperties?.udid, "00008130-000A1234567890AB")

        let text = DevicectlDeviceList.describe(devices)
        XCTAssertTrue(text.contains("iPhone 15 Pro Max"))
        XCTAssertTrue(text.contains("udid=00008130-000A1234567890AB"))
        XCTAssertTrue(text.contains("transport=wired"))
    }

    func testMissingFieldsDoNotFailParsing() throws {
        let minimal = #"{"result":{"devices":[{"identifier":"abc"}]}}"#
        let devices = try DevicectlDeviceList.parse(Data(minimal.utf8))
        XCTAssertEqual(devices.count, 1)
        let text = DevicectlDeviceList.describe(devices)
        XCTAssertTrue(text.contains("udid=abc"))
    }

    func testEmptyListDescribesRemediation() throws {
        let empty = #"{"result":{"devices":[]}}"#
        let devices = try DevicectlDeviceList.parse(Data(empty.utf8))
        XCTAssertTrue(DevicectlDeviceList.describe(devices).contains("No physical devices"))
    }

    func testGarbageThrowsMirrorError() {
        XCTAssertThrowsError(try DevicectlDeviceList.parse(Data("not json".utf8))) { error in
            XCTAssertTrue(error is MirrorError)
        }
    }
}
