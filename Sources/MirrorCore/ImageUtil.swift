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
}
