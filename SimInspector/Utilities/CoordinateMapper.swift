import Foundation
import CoreGraphics
import AppKit

private func debugLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    let path = "/tmp/siminspector_debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

/// Maps macOS screen coordinates to iOS Simulator coordinates.
struct CoordinateMapper {
    /// The iOS content area in screen coordinates (top-left origin, like CGWindowList).
    let contentRect: CGRect

    /// The iOS device logical resolution (e.g., 390×844).
    let deviceSize: CGSize

    /// Scale: iOS points → screen points.
    var scaleFactor: CGFloat {
        guard deviceSize.width > 0 else { return 1.0 }
        return contentRect.width / deviceSize.width
    }

    /// Convert a macOS screen point (top-left origin) to iOS point coordinates.
    func macScreenToiOS(_ screenPoint: CGPoint) -> CGPoint? {
        guard contentRect.contains(screenPoint) else { return nil }
        let relativeX = screenPoint.x - contentRect.origin.x
        let relativeY = screenPoint.y - contentRect.origin.y
        return CGPoint(x: relativeX / scaleFactor, y: relativeY / scaleFactor)
    }

    /// Convert an iOS element frame to a macOS screen rect (top-left origin).
    func iOSFrameToScreen(_ iosFrame: CGRect) -> CGRect {
        CGRect(
            x: contentRect.origin.x + iosFrame.origin.x * scaleFactor,
            y: contentRect.origin.y + iosFrame.origin.y * scaleFactor,
            width: iosFrame.width * scaleFactor,
            height: iosFrame.height * scaleFactor
        )
    }

    // MARK: - Accessibility-based Chrome Detection

    /// Detect the Simulator's device rendering area position using the Accessibility API.
    /// Returns the content view's frame (in top-left screen coordinates) within the Simulator window.
    static func detectSimulatorContentFrame() -> CGRect? {
        guard let simApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else {
            debugLog("[AX] Simulator app not found")
            return nil
        }

        // Check and request accessibility permission
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !trusted {
            debugLog("[AX] Not trusted for Accessibility — requesting permission")
            return nil
        }

        let axApp = AXUIElementCreateApplication(simApp.processIdentifier)

        // Get windows
        var windowsRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            debugLog("[AX] Failed to get Simulator windows: \(result.rawValue)")
            return nil
        }

        guard let mainWindow = windows.first else {
            debugLog("[AX] No Simulator windows found")
            return nil
        }

        // Get window position and size (AX uses top-left coordinates)
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(mainWindow, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(mainWindow, kAXSizeAttribute as CFString, &sizeRef)

        var windowPos = CGPoint.zero
        var windowSize = CGSize.zero
        if let posRef = posRef {
            AXValueGetValue(posRef as! AXValue, .cgPoint, &windowPos)
        }
        if let sizeRef = sizeRef {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &windowSize)
        }
        debugLog("[AX] Window pos=\(windowPos), size=\(windowSize)")

        // Explore children to find the largest child (the device rendering area)
        var childrenRef: AnyObject?
        AXUIElementCopyAttributeValue(mainWindow, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else {
            debugLog("[AX] No children found")
            return nil
        }

        var bestChild: (pos: CGPoint, size: CGSize)?

        for (i, child) in children.enumerated() {
            var roleRef: AnyObject?
            var childPosRef: AnyObject?
            var childSizeRef: AnyObject?
            var subroleRef: AnyObject?

            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subroleRef)
            AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &childPosRef)
            AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &childSizeRef)

            let role = roleRef as? String ?? "unknown"
            let subrole = subroleRef as? String ?? ""

            var cPos = CGPoint.zero
            var cSize = CGSize.zero
            if let childPosRef = childPosRef {
                AXValueGetValue(childPosRef as! AXValue, .cgPoint, &cPos)
            }
            if let childSizeRef = childSizeRef {
                AXValueGetValue(childSizeRef as! AXValue, .cgSize, &cSize)
            }

            debugLog("[AX] Child[\(i)]: role=\(role), subrole=\(subrole), pos=\(cPos), size=\(cSize)")

            // The device rendering area is the largest child view
            if cSize.height > 100 && cSize.width > 100 {
                if bestChild == nil || cSize.height * cSize.width > bestChild!.size.height * bestChild!.size.width {
                    bestChild = (cPos, cSize)
                }
            }
        }

        if let child = bestChild {
            let frame = CGRect(origin: child.pos, size: child.size)
            debugLog("[AX] Best content child frame: \(frame)")
            return frame
        }

        debugLog("[AX] No suitable content child found")
        return nil
    }

    // MARK: - Fallback (no calibration)

    /// Fallback: estimate content rect from window frame with a rough offset.
    static func autoDetect(contentRect: CGRect) -> CoordinateMapper {
        let aspect = contentRect.width / contentRect.height

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

        var bestMatch = devices[2].size
        var bestDiff: CGFloat = .infinity

        for device in devices {
            let deviceAspect = device.size.width / device.size.height
            let diff = abs(aspect - deviceAspect)
            if diff < bestDiff {
                bestDiff = diff
                bestMatch = device.size
            }
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
