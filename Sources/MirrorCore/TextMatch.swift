import CoreGraphics
import Foundation

/// A piece of text recognized on screen, with its bounding box in screenshot
/// pixel coordinates (origin top-left, y down).
public struct OCRElement: Equatable, Sendable {
    public let text: String
    public let confidence: Double
    public let box: CGRect

    public init(text: String, confidence: Double, box: CGRect) {
        self.text = text
        self.confidence = confidence
        self.box = box
    }

    public var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

public enum VisionGeometry {
    /// Converts a Vision normalized rect (origin bottom-left, y up, 0–1) to
    /// pixel coordinates with origin top-left, y down.
    public static func pixelRect(fromNormalized r: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: r.minX * imageSize.width,
            y: (1 - r.maxY) * imageSize.height,
            width: r.width * imageSize.width,
            height: r.height * imageSize.height
        )
    }
}

public enum TextMatch {
    /// Finds OCR elements matching `query`, best matches first:
    /// exact (case-insensitive) equality, then prefix, then substring.
    /// Within the same rank, preserves top-to-bottom reading order as given.
    public static func find(_ query: String, in elements: [OCRElement], exact: Bool = false) -> [OCRElement] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        func rank(_ element: OCRElement) -> Int? {
            let haystack = element.text.trimmingCharacters(in: .whitespaces).lowercased()
            if haystack == needle { return 0 }
            if exact { return nil }
            if haystack.hasPrefix(needle) { return 1 }
            if haystack.contains(needle) { return 2 }
            return nil
        }

        var ranked: [(rank: Int, index: Int, element: OCRElement)] = []
        for (index, element) in elements.enumerated() {
            if let r = rank(element) {
                ranked.append((rank: r, index: index, element: element))
            }
        }
        ranked.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.index < b.index
        }
        return ranked.map { $0.element }
    }
}
