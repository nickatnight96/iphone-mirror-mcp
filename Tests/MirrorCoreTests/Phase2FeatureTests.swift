import CoreGraphics
import XCTest
@testable import MirrorCore

/// Phase-2 feature units: the perceptual frame diff behind
/// wait_for_screen_change and the annotation renderer.
final class Phase2FeatureTests: XCTestCase {
    private func solidImage(r: CGFloat, g: CGFloat, b: CGFloat, size: Int = 32) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try XCTUnwrap(context.makeImage())
    }

    func testIdenticalImagesDiffToZero() throws {
        let image = try solidImage(r: 0.5, g: 0.5, b: 0.5)
        XCTAssertEqual(ImageUtil.meanAbsDifference(image, image), 0, accuracy: 0.005)
    }

    func testBlackVersusWhiteDiffIsFull() throws {
        let black = try solidImage(r: 0, g: 0, b: 0)
        let white = try solidImage(r: 1, g: 1, b: 1)
        XCTAssertEqual(ImageUtil.meanAbsDifference(black, white), 1, accuracy: 0.02)
    }

    func testSmallChangeLandsBetweenThresholds() throws {
        // One quarter of the image flips black→white: expect ~0.25 difference —
        // above the 0.02 change threshold, far below "everything changed".
        let size = 32
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size / 2))
        let quarterWhite = try XCTUnwrap(context.makeImage())
        let black = try solidImage(r: 0, g: 0, b: 0)

        let difference = ImageUtil.meanAbsDifference(black, quarterWhite)
        XCTAssertGreaterThan(difference, 0.15)
        XCTAssertLessThan(difference, 0.35)
    }

    func testDifferentResolutionsCompareAfterResampling() throws {
        let small = try solidImage(r: 1, g: 0, b: 0, size: 16)
        let large = try solidImage(r: 1, g: 0, b: 0, size: 128)
        XCTAssertEqual(ImageUtil.meanAbsDifference(small, large), 0, accuracy: 0.02)
    }

    func testAnnotateChangesPixelsAndPreservesSize() throws {
        let base = try solidImage(r: 0.2, g: 0.2, b: 0.2, size: 64)
        let annotated = try ImageUtil.annotate(
            base, boxes: [(CGRect(x: 8, y: 8, width: 24, height: 16), "0")])
        XCTAssertEqual(annotated.width, base.width)
        XCTAssertEqual(annotated.height, base.height)
        XCTAssertGreaterThan(
            ImageUtil.meanAbsDifference(base, annotated), 0.005,
            "annotation drew nothing")
    }

    func testAnnotateWithNoBoxesIsIdentity() throws {
        let base = try solidImage(r: 0.6, g: 0.3, b: 0.1, size: 64)
        let annotated = try ImageUtil.annotate(base, boxes: [])
        XCTAssertEqual(ImageUtil.meanAbsDifference(base, annotated), 0, accuracy: 0.005)
    }
}
