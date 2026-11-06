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

    /// devicectl lists every device the Mac has ever seen, in no useful
    /// order. The default for run_on_iphone must be a paired iPhone, not the
    /// first row.
    let mixedFleetJSON = """
    {"result":{"devices":[
      {"identifier":"ipad","connectionProperties":{"pairingState":"paired"},
       "deviceProperties":{"name":"Office iPad"},
       "hardwareProperties":{"udid":"IPAD-UDID","deviceType":"iPad14,3","platform":"iOS"}},
      {"identifier":"watch","connectionProperties":{"pairingState":"paired"},
       "deviceProperties":{"name":"Watch"},
       "hardwareProperties":{"udid":"WATCH-UDID","deviceType":"Watch6,1","platform":"watchOS"}},
      {"identifier":"old","connectionProperties":{"pairingState":"unpaired"},
       "deviceProperties":{"name":"Old iPhone"},
       "hardwareProperties":{"udid":"OLD-UDID","deviceType":"iPhone15,2","platform":"iOS"}},
      {"identifier":"mine","connectionProperties":{"pairingState":"paired"},
       "deviceProperties":{"name":"My iPhone"},
       "hardwareProperties":{"udid":"MINE-UDID","deviceType":"iPhone16,2","platform":"iOS"}}
    ]}}
    """

    func testDefaultDeviceIsFirstPairedIPhone() throws {
        let devices = try DevicectlDeviceList.parse(Data(mixedFleetJSON.utf8))
        let picked = try XcodeTools.resolveDevice(nil, in: devices)
        XCTAssertEqual(picked.identifier, "MINE-UDID")
        XCTAssertEqual(picked.name, "My iPhone")
        // An explicit query still reaches any device, iPad included.
        XCTAssertEqual(try XcodeTools.resolveDevice("office ipad", in: devices).identifier, "IPAD-UDID")
    }

    func testNoPairedIPhoneIsAnError() throws {
        let devices = try DevicectlDeviceList.parse(Data(mixedFleetJSON.utf8)).filter {
            $0.hardwareProperties?.udid != "MINE-UDID"
        }
        XCTAssertThrowsError(try XcodeTools.resolveDevice(nil, in: devices)) { error in
            let message = (error as? MirrorError)?.message ?? ""
            XCTAssertTrue(message.contains("Office iPad"), "error should list what was found: \(message)")
            XCTAssertTrue(message.contains("Old iPhone"), message)
        }
    }
}
