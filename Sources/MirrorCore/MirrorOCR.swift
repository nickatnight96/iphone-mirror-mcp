import CoreGraphics
import Foundation
import Vision

/// Recognizes on-screen text with Apple Vision. Results come back in the
/// screenshot's pixel coordinate space (origin top-left) — the same space
/// every tap/swipe tool accepts, so an OCR box center can be tapped directly.
public enum MirrorOCR {
    public static func recognizeText(
        in image: CGImage,
        fast: Bool = false,
        languages: [String] = ["en-US"]
    ) throws -> [OCRElement] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw MirrorError("Vision text recognition failed: \(error.localizedDescription)")
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        let elements: [OCRElement] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = VisionGeometry.pixelRect(
                fromNormalized: observation.boundingBox, imageSize: imageSize)
            return OCRElement(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                box: box
            )
        }
        return readingOrder(elements)
    }

    /// Reading order: top-to-bottom rows, left-to-right within a row.
    /// Rows are fixed 16-pixel buckets — a tolerance-based comparator is not
    /// a strict weak ordering (transitivity breaks when y values chain), and
    /// sorted(by:) with an invalid predicate returns unspecified order.
    static func readingOrder(_ elements: [OCRElement]) -> [OCRElement] {
        elements.sorted { a, b in
            let rowA = Int(a.box.minY / 16)
            let rowB = Int(b.box.minY / 16)
            if rowA != rowB { return rowA < rowB }
            if a.box.minX != b.box.minX { return a.box.minX < b.box.minX }
            return a.box.minY < b.box.minY
        }
    }
}
