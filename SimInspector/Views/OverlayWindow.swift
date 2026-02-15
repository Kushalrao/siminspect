import AppKit
import SwiftUI

/// Transparent window that overlays the Simulator to draw highlight rectangles.
class OverlayWindow: NSWindow {
    private let highlightView = HighlightView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView = highlightView
    }

    /// Update position to match the Simulator window.
    func updateFrame(to rect: CGRect) {
        // Convert from CGWindowList coordinates (top-left origin) to NSScreen (bottom-left origin)
        guard let screen = NSScreen.main else { return }
        let flippedY = screen.frame.height - rect.origin.y - rect.height
        let nsRect = NSRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
        setFrame(nsRect, display: true)
    }

    /// Highlight a specific element rect (in screen coordinates, top-left origin).
    func highlightRect(_ rect: CGRect?) {
        guard let screen = NSScreen.main else { return }
        if let rect {
            // Convert to window-local coordinates
            let windowFrame = frame
            let flippedY = screen.frame.height - rect.origin.y - rect.height
            let localRect = NSRect(
                x: rect.origin.x - windowFrame.origin.x,
                y: flippedY - windowFrame.origin.y,
                width: rect.width,
                height: rect.height
            )
            highlightView.highlightRect = localRect
        } else {
            highlightView.highlightRect = nil
        }
        highlightView.needsDisplay = true
    }

    /// Set the mouse event handler for inspect mode.
    func setMouseHandler(_ handler: ((NSPoint) -> Void)?) {
        highlightView.onMouseMoved = handler
    }

    func setClickHandler(_ handler: ((NSPoint) -> Void)?) {
        highlightView.onMouseClicked = handler
    }

    override var canBecomeKey: Bool { true }
}

/// Custom view that draws highlight rectangles and tracks mouse.
class HighlightView: NSView {
    var highlightRect: NSRect?
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseClicked: ((NSPoint) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = highlightRect else { return }

        // Blue semi-transparent fill
        NSColor.systemBlue.withAlphaComponent(0.2).setFill()
        let path = NSBezierPath(rect: rect)
        path.fill()

        // Blue border
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 2
        path.stroke()

        // Size label
        let sizeText = String(format: "%.0f × %.0f", rect.width, rect.height)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.9)
        ]
        let textSize = sizeText.size(withAttributes: attrs)
        let textRect = NSRect(
            x: rect.origin.x,
            y: rect.origin.y - textSize.height - 2,
            width: textSize.width + 6,
            height: textSize.height + 2
        )

        NSColor.systemBlue.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: textRect, xRadius: 3, yRadius: 3).fill()
        sizeText.draw(at: NSPoint(x: textRect.origin.x + 3, y: textRect.origin.y + 1), withAttributes: attrs)
    }

    override func mouseMoved(with event: NSEvent) {
        // Convert to screen coordinates for the mapper
        guard let window = window else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        onMouseMoved?(screenPoint)
    }

    override func mouseDown(with event: NSEvent) {
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        onMouseClicked?(screenPoint)
    }

    override var acceptsFirstResponder: Bool { true }
}
