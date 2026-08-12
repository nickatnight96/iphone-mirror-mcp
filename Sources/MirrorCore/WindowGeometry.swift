import CoreGraphics
import Foundation

/// Maps between screenshot pixel coordinates and global screen coordinates.
///
/// Contract used by every interaction tool: coordinates passed to tap/swipe/etc.
/// are **pixel coordinates in the most recent screenshot** of the iPhone
/// Mirroring window (origin top-left, y down). This struct converts them to the
/// CoreGraphics global coordinate space used by CGEvent (also top-left origin,
/// y down), so a model can look at a screenshot and tap exactly what it sees.
public struct WindowGeometry: Sendable, Equatable {
    /// CGWindow id of the mirroring window (for capture APIs).
    public let windowID: UInt32
    /// Window bounds in global screen points (CG coordinates: origin at the
    /// top-left of the main display, y increasing downward).
    public let boundsPoints: CGRect
    /// Pixel size of the screenshot this geometry was computed against.
    public let imagePixelSize: CGSize

    public init(windowID: UInt32, boundsPoints: CGRect, imagePixelSize: CGSize) {
        self.windowID = windowID
        self.boundsPoints = boundsPoints
        self.imagePixelSize = imagePixelSize
    }

    /// Pixels per point, per axis. Normally uniform (the display backing scale),
    /// but kept per-axis so a resized capture still maps correctly.
    public var pixelsPerPoint: CGSize {
        CGSize(
            width: imagePixelSize.width / max(boundsPoints.width, 1),
            height: imagePixelSize.height / max(boundsPoints.height, 1)
        )
    }

    /// Converts a screenshot pixel coordinate to a global screen point.
    /// Throws when the coordinate lies outside the screenshot. The inclusive
    /// far edge (x == width, y == height) is accepted for caller friendliness
    /// but clamped half a pixel inward so the synthesized click can never
    /// land just past the window's right/bottom edge.
    public func screenPoint(fromPixelX x: Double, pixelY y: Double) throws -> CGPoint {
        guard x >= 0, y >= 0, x <= imagePixelSize.width, y <= imagePixelSize.height else {
            throw MirrorError(
                "Coordinate (\(x), \(y)) is outside the screenshot bounds \(Int(imagePixelSize.width))x\(Int(imagePixelSize.height)).",
                remediation: "Take a fresh screenshot and use pixel coordinates within it."
            )
        }
        let clampedX = min(x, imagePixelSize.width - 0.5)
        let clampedY = min(y, imagePixelSize.height - 0.5)
        let scale = pixelsPerPoint
        return CGPoint(
            x: boundsPoints.origin.x + clampedX / scale.width,
            y: boundsPoints.origin.y + clampedY / scale.height
        )
    }

    /// Converts a global screen point back to screenshot pixel coordinates.
    public func pixel(fromScreenPoint p: CGPoint) -> CGPoint {
        let scale = pixelsPerPoint
        return CGPoint(
            x: (p.x - boundsPoints.origin.x) * scale.width,
            y: (p.y - boundsPoints.origin.y) * scale.height
        )
    }
}
