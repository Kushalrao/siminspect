import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: InspectorPanel?
    var windowTracker: WindowTracker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request accessibility permissions
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        // Close any windows SwiftUI may have created (Settings scene artifact)
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is InspectorPanel) && !(window is OverlayWindow) {
                window.close()
            }
        }

        // Create the window tracker
        let tracker = WindowTracker()
        windowTracker = tracker

        // Create the panel
        let defaultWidth: CGFloat = 320
        let defaultHeight: CGFloat = 500
        let panelRect = NSRect(x: 200, y: 200, width: defaultWidth, height: defaultHeight)
        let inspectorPanel = InspectorPanel(contentRect: panelRect)
        panel = inspectorPanel

        // Host MainView inside the panel's visual effect view
        let mainView = MainView()
            .environmentObject(tracker)
        let hostingView = NSHostingView(rootView: mainView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // contentView is the NSVisualEffectView — add hosting view as subview
        if let effectView = inspectorPanel.contentView {
            effectView.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            ])
        }

        // Set up frame change callback to reposition panel
        tracker.onFrameChanged = { [weak self] simulatorFrame in
            self?.repositionPanel(simulatorFrame: simulatorFrame)
        }

        // Start tracking — AX attachment is async, so show panel after a short delay
        tracker.startTracking()

        // Give AX time to attach, then show panel positioned next to Simulator
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if let frame = tracker.simulatorWindowFrame {
                self?.repositionPanel(simulatorFrame: frame)
            } else {
                // Show panel anyway so user can see the UI
                inspectorPanel.center()
                inspectorPanel.orderFront(nil)
            }
        }

        // Observe workspace for Simulator quit/launch
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.iphonesimulator" else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func repositionPanel(simulatorFrame: CGRect) {
        guard let panel else { return }

        // simulatorFrame is in AX coordinates (top-left origin)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 900

        // Find which screen contains the Simulator
        let simCenter = CGPoint(x: simulatorFrame.midX, y: simulatorFrame.midY)
        let screen = NSScreen.screens.first(where: { screen in
            let sf = screen.frame
            let topLeftY = primaryHeight - sf.origin.y - sf.height
            let topLeftFrame = CGRect(x: sf.origin.x, y: topLeftY, width: sf.width, height: sf.height)
            return topLeftFrame.contains(simCenter)
        }) ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen else { return }

        let panelWidth = panel.frame.width > 0 ? panel.frame.width : 320
        let visibleFrame = screen.visibleFrame

        // Panel height matches Simulator height, clamped to screen
        let panelHeight = min(simulatorFrame.height, visibleFrame.height)

        // Try placing to the RIGHT of Simulator with 8pt gap
        var panelX = simulatorFrame.maxX + 8

        // Check if it goes off-screen
        if panelX + panelWidth > visibleFrame.maxX {
            // Place to LEFT
            panelX = simulatorFrame.minX - panelWidth - 8
        }

        // Convert AX top-left Y to NS bottom-left Y
        let panelY = primaryHeight - simulatorFrame.origin.y - panelHeight

        // Clamp Y to visible frame
        let clampedY = max(visibleFrame.origin.y, min(panelY, visibleFrame.origin.y + visibleFrame.height - panelHeight))

        let newFrame = NSRect(x: panelX, y: clampedY, width: panelWidth, height: panelHeight)
        panel.setFrame(newFrame, display: true, animate: false)

        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
