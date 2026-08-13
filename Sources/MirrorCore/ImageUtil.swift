import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageUtil {
    public static func pngData(from image: CGImage) throws -> Data {
        try encode(image, type: UTType.png, properties: nil)
    }

    public static func jpegData(from image: CGImage, quality: Double = 0.85) throws -> Data {
        try encode(image, type: UTType.jpeg,
                   properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]?) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw MirrorError("Could not create image encoder for \(type.identifier).")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else {
            throw MirrorError("Image encoding failed for \(type.identifier).")
        }
        return data as Data
    }

    /// Scales the image down so its longest side is `maxDimension` pixels,
    /// preserving aspect ratio. Returns the original if already small enough
    /// or if `maxDimension` is not positive.
    public static func downscaled(_ image: CGImage, maxDimension: Int) -> CGImage {
        guard maxDimension > 0 else { return image }
        let longest = max(image.width, image.height)
        guard longest > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Mean absolute per-channel difference between two images, normalized
    /// to 0…1 (0 = identical, 1 = inverted). Both are rendered into small
    /// same-size RGBA buffers first, so differing resolutions compare fine.
    /// Powers wait_for_screen_change.
    public static func meanAbsDifference(_ a: CGImage, _ b: CGImage, sampleSize: Int = 64) -> Double {
        let size = max(8, sampleSize)
        func buffer(_ image: CGImage) -> [UInt8]? {
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            guard let context = CGContext(
                data: &pixels, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return pixels
        }
        guard let bufferA = buffer(a), let bufferB = buffer(b) else { return 1 }
        var total = 0
        for index in 0..<bufferA.count where index % 4 != 3 {  // skip alpha
            total += abs(Int(bufferA[index]) - Int(bufferB[index]))
        }
        let channelCount = size * size * 3
        return Double(total) / Double(channelCount * 255)
    }

    /// Draws numbered boxes over the image — the annotated screenshot that
    /// makes OCR coordinates visible at a glance. `boxes` are in image pixel
    /// coordinates (origin top-left, like every tool coordinate).
    public static func annotate(_ image: CGImage, boxes: [(rect: CGRect, label: String)]) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw MirrorError("Could not create annotation canvas.") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let stroke = NSColor.systemRed
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: CGFloat(max(14, height / 80))),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.systemRed,
        ]
        for box in boxes {
            // Tool coordinates are top-left-origin; CG drawing is bottom-left.
            let flipped = CGRect(
                x: box.rect.origin.x,
                y: CGFloat(height) - box.rect.origin.y - box.rect.height,
                width: box.rect.width, height: box.rect.height)
            stroke.setStroke()
            let path = NSBezierPath(rect: flipped)
            path.lineWidth = 3
            path.stroke()
            (box.label as NSString).draw(
                at: CGPoint(x: flipped.origin.x, y: flipped.maxY + 2),
                withAttributes: attributes)
        }
        guard let annotated = context.makeImage() else {
            throw MirrorError("Annotation rendering failed.")
        }
        return annotated
    }
}
