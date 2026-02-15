import Foundation
import CoreGraphics

/// Maps macOS screen coordinates to iOS Simulator coordinates.
struct CoordinateMapper {
    /// The Simulator content area in screen coordinates (excluding title bar/chrome).
    let contentRect: CGRect

    /// The iOS device logical resolution (e.g., 393×852 for iPhone 15).
    let deviceSize: CGSize

    /// Computed scale factor from iOS points to screen points.
    var scaleFactor: CGFloat {
        guard deviceSize.width > 0 else { return 1.0 }
        return contentRect.width / deviceSize.width
    }

    /// Convert a macOS screen point to iOS point coordinates.
    /// macOS screen coordinates have origin at bottom-left,
    /// but CGWindowListCopyWindowInfo returns top-left origin.
    func macScreenToiOS(_ screenPoint: CGPoint) -> CGPoint? {
        // Check if point is within the content rect
        guard contentRect.contains(screenPoint) else { return nil }

        let relativeX = screenPoint.x - contentRect.origin.x
        let relativeY = screenPoint.y - contentRect.origin.y

        let iosX = relativeX / scaleFactor
        let iosY = relativeY / scaleFactor

        return CGPoint(x: iosX, y: iosY)
    }

    /// Convert an iOS element frame to a macOS screen rect (for drawing highlights).
    func iOSFrameToScreen(_ iosFrame: CGRect) -> CGRect {
        CGRect(
            x: contentRect.origin.x + iosFrame.origin.x * scaleFactor,
            y: contentRect.origin.y + iosFrame.origin.y * scaleFactor,
            width: iosFrame.width * scaleFactor,
            height: iosFrame.height * scaleFactor
        )
    }

    /// Create a mapper for common device sizes.
    /// Tries to infer the device resolution from the content area aspect ratio.
    static func autoDetect(contentRect: CGRect) -> CoordinateMapper {
        let aspect = contentRect.width / contentRect.height

        // Common iOS device logical sizes (portrait)
        let devices: [(name: String, size: CGSize)] = [
            ("iPhone SE", CGSize(width: 375, height: 667)),
            ("iPhone 14", CGSize(width: 390, height: 844)),
            ("iPhone 15", CGSize(width: 393, height: 852)),
            ("iPhone 15 Pro Max", CGSize(width: 430, height: 932)),
            ("iPhone 16", CGSize(width: 393, height: 852)),
            ("iPad mini", CGSize(width: 744, height: 1133)),
            ("iPad Air", CGSize(width: 820, height: 1180)),
            ("iPad Pro 11\"", CGSize(width: 834, height: 1194)),
            ("iPad Pro 13\"", CGSize(width: 1024, height: 1366)),
        ]

        // Find the best matching device
        var bestMatch = devices[2].size // default to iPhone 15
        var bestDiff: CGFloat = .infinity

        for device in devices {
            let deviceAspect = device.size.width / device.size.height
            let diff = abs(aspect - deviceAspect)
            if diff < bestDiff {
                bestDiff = diff
                bestMatch = device.size
            }
            // Also check landscape
            let landscapeAspect = device.size.height / device.size.width
            let landscapeDiff = abs(aspect - landscapeAspect)
            if landscapeDiff < bestDiff {
                bestDiff = landscapeDiff
                bestMatch = CGSize(width: device.size.height, height: device.size.width)
            }
        }

        return CoordinateMapper(contentRect: contentRect, deviceSize: bestMatch)
    }
}
