import CoreGraphics
import Foundation

/// Grayscale normalized cross-correlation template matching — the way to
/// find icon-only UI (no text for OCR) on the mirrored screen. Matching runs
/// coarse (downsampled, strided) and refines the peak locally, so a full-res
/// 696×1532 screen stays fast without dependencies.
public enum TemplateMatch {
    public struct Match: Equatable, Sendable {
        /// Center of the found region, in SCREEN pixel coordinates.
        public let center: CGPoint
        /// The matched region.
        public let box: CGRect
        /// Normalized correlation score 0…1 (1 = pixel-identical).
        public let score: Double
    }

    /// Luminance buffer for an image scaled to `width` pixels wide.
    static func grayBuffer(_ image: CGImage, width: Int) -> (pixels: [Double], width: Int, height: Int)? {
        let scale = Double(width) / Double(image.width)
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var gray = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let base = i * 4
            gray[i] = 0.299 * Double(rgba[base]) + 0.587 * Double(rgba[base + 1]) + 0.114 * Double(rgba[base + 2])
        }
        return (gray, width, height)
    }

    /// Zero-mean NCC of `template` placed at (x, y) in `screen`.
    static func score(
        screen: [Double], screenWidth: Int,
        template: [Double], templateWidth: Int, templateHeight: Int,
        atX x: Int, y: Int,
        templateMean: Double, templateNorm: Double
    ) -> Double {
        var regionSum = 0.0
        for row in 0..<templateHeight {
            let screenRow = (y + row) * screenWidth + x
            for col in 0..<templateWidth {
                regionSum += screen[screenRow + col]
            }
        }
        let count = Double(templateWidth * templateHeight)
        let regionMean = regionSum / count

        var cross = 0.0
        var regionSquares = 0.0
        for row in 0..<templateHeight {
            let screenRow = (y + row) * screenWidth + x
            let templateRow = row * templateWidth
            for col in 0..<templateWidth {
                let screenValue = screen[screenRow + col] - regionMean
                let templateValue = template[templateRow + col] - templateMean
                cross += screenValue * templateValue
                regionSquares += screenValue * screenValue
            }
        }
        let denominator = (regionSquares * templateNorm).squareRoot()
        guard denominator > 1e-9 else {
            // Flat region vs flat template: identical means = match.
            return regionSquares < 1e-9 && templateNorm < 1e-9 ? 1 : 0
        }
        return max(0, cross / denominator)
    }

    /// Finds the best placements of `template` in `screen`. Coordinates come
    /// back in SCREEN pixel space (the tool coordinate space when `screen`
    /// is a full-resolution capture). Templates should be crops from a
    /// previous screenshot at the same resolution (scale 1); pass extra
    /// scales when the template's source scale is unknown.
    public static func find(
        template templateImage: CGImage, in screenImage: CGImage,
        minScore: Double = 0.8, scales: [Double] = [1.0], maxMatches: Int = 5
    ) -> [Match] {
        // Coarse space: screen capped to 224 wide — with the ±refinement
        // below, center accuracy stays within ~12 full-res pixels, far
        // inside a 88px (44pt) tap target.
        let coarseWidth = min(224, screenImage.width)
        let downFactor = Double(screenImage.width) / Double(coarseWidth)
        guard let screen = grayBuffer(screenImage, width: coarseWidth) else { return [] }

        var candidates: [Match] = []
        for scale in scales {
            let templateCoarseWidth = max(4, Int((Double(templateImage.width) * scale / downFactor).rounded()))
            guard let template = grayBuffer(templateImage, width: templateCoarseWidth),
                  template.width < screen.width, template.height < screen.height else { continue }

            let templateMean = template.pixels.reduce(0, +) / Double(template.pixels.count)
            let templateNorm = template.pixels.reduce(0.0) {
                $0 + ($1 - templateMean) * ($1 - templateMean)
            }

            // Coarse scan with stride 2, then local refinement. The gate is
            // deliberately loose: a high-frequency template's correlation
            // collapses one pixel off-peak, and refinement recovers it.
            var best: [(x: Int, y: Int, score: Double)] = []
            let strideStep = 2
            let candidateGate = max(0.35, minScore - 0.3)
            var y = 0
            while y <= screen.height - template.height {
                var x = 0
                while x <= screen.width - template.width {
                    let value = score(
                        screen: screen.pixels, screenWidth: screen.width,
                        template: template.pixels, templateWidth: template.width,
                        templateHeight: template.height, atX: x, y: y,
                        templateMean: templateMean, templateNorm: templateNorm)
                    if value >= candidateGate {
                        best.append((x, y, value))
                    }
                    x += strideStep
                }
                y += strideStep
            }

            for candidate in best.sorted(by: { $0.score > $1.score }).prefix(20) {
                var top = candidate
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = candidate.x + dx, ny = candidate.y + dy
                        guard nx >= 0, ny >= 0,
                              nx <= screen.width - template.width,
                              ny <= screen.height - template.height else { continue }
                        let value = score(
                            screen: screen.pixels, screenWidth: screen.width,
                            template: template.pixels, templateWidth: template.width,
                            templateHeight: template.height, atX: nx, y: ny,
                            templateMean: templateMean, templateNorm: templateNorm)
                        if value > top.score { top = (nx, ny, value) }
                    }
                }
                guard top.score >= minScore else { continue }
                let box = CGRect(
                    x: Double(top.x) * downFactor,
                    y: Double(top.y) * downFactor,
                    width: Double(template.width) * downFactor,
                    height: Double(template.height) * downFactor)
                candidates.append(Match(
                    center: CGPoint(x: box.midX, y: box.midY), box: box, score: top.score))
            }
        }

        // Deduplicate overlapping hits (keep the best-scoring one).
        var results: [Match] = []
        for match in candidates.sorted(by: { $0.score > $1.score }) {
            let overlaps = results.contains { existing in
                let dx = existing.center.x - match.center.x
                let dy = existing.center.y - match.center.y
                return (dx * dx + dy * dy).squareRoot() < max(match.box.width, match.box.height) / 2
            }
            if !overlaps { results.append(match) }
            if results.count >= maxMatches { break }
        }
        return results
    }
}
