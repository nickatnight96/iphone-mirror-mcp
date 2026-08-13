import CoreGraphics
import XCTest
@testable import MirrorCore

final class NotificationBridgeTests: XCTestCase {
    func testDescribeEmptyExplainsBannerLifetime() {
        let text = NotificationBridge.describe([])
        XCTAssertTrue(text.contains("No notification banners"))
        XCTAssertTrue(text.contains("disappear"), "should explain banners auto-dismiss")
    }

    func testDescribeListsIndexedBanners() {
        let banners = [
            NotificationBridge.Banner(lines: ["Messages", "Ally", "hi"], frame: CGRect(x: 0, y: 10, width: 300, height: 60)),
            NotificationBridge.Banner(lines: ["Mail", "Re: plans"], frame: CGRect(x: 0, y: 80, width: 300, height: 60)),
        ]
        let text = NotificationBridge.describe(banners)
        XCTAssertTrue(text.contains("0: Messages — Ally — hi"))
        XCTAssertTrue(text.contains("1: Mail — Re: plans"))
    }

    func testClickOutOfRangeThrows() {
        // No banners on a quiet screen → both empty-and-index errors funnel
        // through MirrorError, never a crash.
        XCTAssertThrowsError(try NotificationBridge.click(index: 99)) {
            XCTAssertTrue($0 is MirrorError)
        }
    }
}
