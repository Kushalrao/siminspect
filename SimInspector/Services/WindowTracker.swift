import Foundation
import AppKit
import CoreGraphics

/// Tracks the Simulator.app window position and size using AXObserver for event-driven updates.
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

    /// Callback fired whenever the Simulator frame changes (for panel repositioning).
    var onFrameChanged: ((CGRect) -> Void)?

    // AX state
    private var axObserver: AXObserver?
    private var simulatorApp: AXUIElement?
    private var simulatorWindow: AXUIElement?
    private var simulatorPID: pid_t = 0

    // Drag tracking monitors
    private var dragMonitor: Any?
    private var mouseUpMonitor: Any?

    // Workspace observers
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    func startTracking() {
        stopTracking()
        setupWorkspaceObservers()

        // Attach to Simulator if it's already running
        if let simApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
            attachToSimulator(pid: simApp.processIdentifier)
        }
    }

    func stopTracking() {
        detachFromSimulator()
        removeWorkspaceObservers()
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

    // MARK: - Workspace Observers

    private func setupWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        launchObserver = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.iphonesimulator" else { return }
            Task { @MainActor [weak self] in
                // Small delay for window to appear
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.attachToSimulator(pid: app.processIdentifier)
            }
        }

        terminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.iphonesimulator" else { return }
            Task { @MainActor [weak self] in
                self?.detachFromSimulator()
                self?.simulatorWindowFrame = nil
                self?.simulatorWindowID = nil
                self?.contentRect = nil
            }
        }
    }

    private func removeWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        if let obs = launchObserver { nc.removeObserver(obs) }
        if let obs = terminateObserver { nc.removeObserver(obs) }
        launchObserver = nil
        terminateObserver = nil
    }

    // MARK: - AXObserver

    private func attachToSimulator(pid: pid_t) {
        detachFromSimulator()
        simulatorPID = pid

        let appElement = AXUIElementCreateApplication(pid)
        simulatorApp = appElement

        // Find the main window
        guard let window = getMainWindow(from: appElement) else { return }
        simulatorWindow = window

        // Create AXObserver
        var observer: AXObserver?
        let callbackPtr = Unmanaged.passUnretained(self).toOpaque()

        guard AXObserverCreate(pid, axCallback, &observer) == .success,
              let observer else { return }
        axObserver = observer

        // Register for window move/resize on the window element
        AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, callbackPtr)
        AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, callbackPtr)

        // Register for focused window change on the app element (handles switching sim windows)
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, callbackPtr)

        // Add observer to run loop
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        // Get initial frame
        updateWindowFrame()
        setupDragMonitor()
    }

    private func detachFromSimulator() {
        removeDragMonitor()

        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

            if let window = simulatorWindow {
                AXObserverRemoveNotification(observer, window, kAXMovedNotification as CFString)
                AXObserverRemoveNotification(observer, window, kAXResizedNotification as CFString)
            }
            if let app = simulatorApp {
                AXObserverRemoveNotification(observer, app, kAXFocusedWindowChangedNotification as CFString)
            }
        }

        axObserver = nil
        simulatorApp = nil
        simulatorWindow = nil
        simulatorPID = 0
    }

    private func getMainWindow(from appElement: AXUIElement) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let firstWindow = windows.first else { return nil }
        return firstWindow
    }

    // MARK: - Drag Monitoring (for smooth tracking during drags)

    private func setupDragMonitor() {
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateWindowFrame()
            }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateWindowFrame()
            }
        }
    }

    private func removeDragMonitor() {
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
    }

    // MARK: - Frame Update

    func handleAXNotification(_ notification: CFString, element: AXUIElement) {
        let notifName = notification as String

        if notifName == kAXFocusedWindowChangedNotification as String {
            // The focused window changed — re-attach to track the new window
            if let app = simulatorApp, let window = getMainWindow(from: app) {
                // Remove old window notifications
                if let observer = axObserver, let oldWindow = simulatorWindow {
                    AXObserverRemoveNotification(observer, oldWindow, kAXMovedNotification as CFString)
                    AXObserverRemoveNotification(observer, oldWindow, kAXResizedNotification as CFString)
                }
                simulatorWindow = window
                // Add notifications on new window
                if let observer = axObserver {
                    let callbackPtr = Unmanaged.passUnretained(self).toOpaque()
                    AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, callbackPtr)
                    AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, callbackPtr)
                }
            }
        }

        updateWindowFrame()
    }

    private func updateWindowFrame() {
        guard let window = simulatorWindow else {
            simulatorWindowFrame = nil
            return
        }

        // Get position (AX coordinates: top-left origin)
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else {
            simulatorWindowFrame = nil
            return
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        let frame = CGRect(origin: position, size: size)

        // Detect resize → reset calibration
        if let oldFrame = simulatorWindowFrame,
           oldFrame.width != frame.width || oldFrame.height != frame.height {
            resetCalibration()
        }

        simulatorWindowFrame = frame
        lookupWindowID()

        // Recompute content rect
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
            let titleBarHeight: CGFloat = 28
            contentRect = CGRect(
                x: frame.origin.x,
                y: frame.origin.y + titleBarHeight,
                width: frame.width,
                height: frame.height - titleBarHeight
            )
        }

        onFrameChanged?(frame)
    }

    /// Look up the CGWindowID from CGWindowList (needed by OverlayWindow).
    private func lookupWindowID() {
        guard simulatorPID != 0 else { return }
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == simulatorPID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }
            simulatorWindowID = window[kCGWindowNumber as String] as? CGWindowID
            return
        }
    }
}

// MARK: - AX Callback (C function)

private func axCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    Task { @MainActor in
        tracker.handleAXNotification(notification, element: element)
    }
}
