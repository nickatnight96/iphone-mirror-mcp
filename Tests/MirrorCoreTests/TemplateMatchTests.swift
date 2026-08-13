import CoreGraphics
import XCTest
@testable import MirrorCore

/// Template matching against synthetic screens: a distinctive pattern is
/// planted at a known position and must be found there — and NOT found when
/// absent.
final class TemplateMatchTests: XCTestCase {
    /// A deterministic "noisy" pattern image (checker + gradient) that NCC
    /// can lock onto — flat colors would match everywhere.
    private func patternImage(size: Int, seed: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for row in 0..<8 {
            for col in 0..<8 {
                let value = CGFloat((row * 8 + col * 3 + seed * 7) % 11) / 11.0
                context.setFillColor(CGColor(srgbRed: value, green: 1 - value, blue: value / 2, alpha: 1))
                let cell = CGFloat(size) / 8
                context.fill(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// A screen with the pattern composited at (x, y) top-left coordinates.
    private func screen(width: Int, height: Int, pattern: CGImage, atX x: Int, y: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.15, green: 0.15, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Composite with top-left math converted to CG's bottom-left origin.
        context.draw(pattern, in: CGRect(
            x: x, y: height - y - pattern.height,
            width: pattern.width, height: pattern.height))
        return try XCTUnwrap(context.makeImage())
    }

    func testFindsPlantedPatternNearItsTrueCenter() throws {
        let pattern = try patternImage(size: 96, seed: 1)
        let screenImage = try screen(width: 640, height: 1280, pattern: pattern, atX: 400, y: 700)

        let matches = TemplateMatch.find(template: pattern, in: screenImage, minScore: 0.7)
        let best = try XCTUnwrap(matches.first, "pattern not found")
        // Coarse matching quantizes; allow a small tolerance (well inside a
        // 44pt/88px tap target).
        XCTAssertEqual(Double(best.center.x), 400 + 48, accuracy: 14)
        XCTAssertEqual(Double(best.center.y), 700 + 48, accuracy: 14)
        XCTAssertGreaterThan(best.score, 0.7)
    }

    func testAbsentPatternIsNotHallucinated() throws {
        let pattern = try patternImage(size: 96, seed: 1)
        let decoy = try patternImage(size: 96, seed: 5)
        let screenImage = try screen(width: 640, height: 1280, pattern: decoy, atX: 100, y: 300)

        let matches = TemplateMatch.find(template: pattern, in: screenImage, minScore: 0.85)
        XCTAssertTrue(matches.isEmpty, "found \(matches.map(\.score)) for a pattern that is not on screen")
    }

    func testOverlappingHitsAreDeduplicated() throws {
        let pattern = try patternImage(size: 96, seed: 2)
        let screenImage = try screen(width: 640, height: 1280, pattern: pattern, atX: 200, y: 500)

        let matches = TemplateMatch.find(template: pattern, in: screenImage, minScore: 0.6)
        // One planted instance → one (deduplicated) match cluster.
        XCTAssertEqual(matches.count, 1, "expected one deduplicated match, got \(matches.count)")
    }

    func testGrayBufferDimensions() throws {
        let pattern = try patternImage(size: 64, seed: 3)
        let buffer = try XCTUnwrap(TemplateMatch.grayBuffer(pattern, width: 32))
        XCTAssertEqual(buffer.width, 32)
        XCTAssertEqual(buffer.height, 32)
        XCTAssertEqual(buffer.pixels.count, 32 * 32)
    }
}
