import CoreGraphics
import XCTest
@testable import MirrorCore

final class ImageUtilTests: XCTestCase {
    func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testPNGEncodingProducesPNGMagicBytes() throws {
        let data = try ImageUtil.pngData(from: makeImage(width: 100, height: 60))
        XCTAssertGreaterThan(data.count, 8)
        XCTAssertEqual([UInt8](data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testJPEGEncodingProducesJFIFMagicBytes() throws {
        let data = try ImageUtil.jpegData(from: makeImage(width: 100, height: 60))
        XCTAssertEqual([UInt8](data.prefix(2)), [0xFF, 0xD8])
    }

    func testDownscalePreservesAspectRatio() {
        let scaled = ImageUtil.downscaled(makeImage(width: 100, height: 60), maxDimension: 50)
        XCTAssertEqual(scaled.width, 50)
        XCTAssertEqual(scaled.height, 30)
    }

    func testDownscaleNoOpWhenSmallEnough() {
        let image = makeImage(width: 40, height: 20)
        let scaled = ImageUtil.downscaled(image, maxDimension: 50)
        XCTAssertEqual(scaled.width, 40)
        XCTAssertEqual(scaled.height, 20)
    }

    func testDownscaleTallImage() {
        let scaled = ImageUtil.downscaled(makeImage(width: 60, height: 100), maxDimension: 50)
        XCTAssertEqual(scaled.width, 30)
        XCTAssertEqual(scaled.height, 50)
    }
}
