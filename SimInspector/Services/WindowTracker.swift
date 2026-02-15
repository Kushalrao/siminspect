import Foundation
import AppKit
import CoreGraphics

/// Tracks the Simulator.app window position and size in real-time.
@MainActor
final class WindowTracker: ObservableObject {
    @Published var simulatorWindowFrame: CGRect?
    @Published var contentRect: CGRect?
    @Published var scaleFactor: CGFloat = 1.0

    /// The CGWindowList window ID for the Simulator window.
    var simulatorWindowID: CGWindowID?

    /// Calibrated offsets: content origin relative to window origin, and iOS scale factor.
    var calibratedOffsetX: CGFloat?
    var calibratedOffsetY: CGFloat?
    var calibratedContentWidth: CGFloat?
    var calibratedContentHeight: CGFloat?

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

    /// Store calibration result.
    func setCalibration(contentRect: CGRect) {
        guard let windowFrame = simulatorWindowFrame else { return }
        calibratedOffsetX = contentRect.origin.x - windowFrame.origin.x
        calibratedOffsetY = contentRect.origin.y - windowFrame.origin.y
        calibratedContentWidth = contentRect.width
        calibratedContentHeight = contentRect.height
    }

    /// Clear calibration (e.g., when window resizes or device changes).
    func resetCalibration() {
        calibratedOffsetX = nil
        calibratedOffsetY = nil
        calibratedContentWidth = nil
        calibratedContentHeight = nil
    }

    /// Whether calibration data is available.
    var isCalibrated: Bool {
        calibratedOffsetX != nil
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

            // Detect if window was resized → reset calibration
            if let oldFrame = simulatorWindowFrame,
               oldFrame.width != frame.width || oldFrame.height != frame.height {
                resetCalibration()
            }

            simulatorWindowFrame = frame
            simulatorWindowID = window[kCGWindowNumber as String] as? CGWindowID

            // Use calibrated content rect if available, otherwise estimate
            if let offX = calibratedOffsetX,
               let offY = calibratedOffsetY,
               let cw = calibratedContentWidth,
               let ch = calibratedContentHeight {
                contentRect = CGRect(
                    x: frame.origin.x + offX,
                    y: frame.origin.y + offY,
                    width: cw,
                    height: ch
                )
            } else {
                // Fallback: rough estimate with 28pt title bar
                let titleBarHeight: CGFloat = 28
                contentRect = CGRect(
                    x: frame.origin.x,
                    y: frame.origin.y + titleBarHeight,
                    width: frame.width,
                    height: frame.height - titleBarHeight
                )
            }

            return
        }

        simulatorWindowFrame = nil
        simulatorWindowID = nil
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
