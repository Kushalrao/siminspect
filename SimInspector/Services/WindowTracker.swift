import Foundation
import AppKit
import CoreGraphics

/// Tracks the Simulator.app window position and size in real-time.
@MainActor
final class WindowTracker: ObservableObject {
    @Published var simulatorWindowFrame: CGRect?
    @Published var contentRect: CGRect?
    @Published var scaleFactor: CGFloat = 1.0

    private var timer: Timer?

    /// Start polling for the Simulator window position.
    func startTracking() {
        stopTracking()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateWindowFrame()
            }
        }
        updateWindowFrame()
    }

    func stopTracking() {
        timer?.invalidate()
        timer = nil
    }

    private func updateWindowFrame() {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            simulatorWindowFrame = nil
            return
        }

        // Find the Simulator.app main window
        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  ownerName == "Simulator",
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 // main window layer
            else { continue }

            let x = boundsDict["X"] as? CGFloat ?? 0
            let y = boundsDict["Y"] as? CGFloat ?? 0
            let width = boundsDict["Width"] as? CGFloat ?? 0
            let height = boundsDict["Height"] as? CGFloat ?? 0

            let frame = CGRect(x: x, y: y, width: width, height: height)
            simulatorWindowFrame = frame

            // Estimate content area (below the title bar and inside bezels)
            // The Simulator title bar is ~28pt, and there's typically no bezel in modern Simulator
            let titleBarHeight: CGFloat = 28
            contentRect = CGRect(
                x: frame.origin.x,
                y: frame.origin.y + titleBarHeight,
                width: frame.width,
                height: frame.height - titleBarHeight
            )

            return
        }

        simulatorWindowFrame = nil
        contentRect = nil
    }

    /// Get the Simulator window name (includes device name).
    func getSimulatorWindowName() -> String? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  ownerName == "Simulator",
                  let name = window[kCGWindowName as String] as? String,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }

            return name
        }
        return nil
    }
}
