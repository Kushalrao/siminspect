import AppKit

/// Borderless floating HUD panel that attaches to the Simulator window.
/// Styled like RocketSim — no title bar, rounded corners, dark vibrancy material.
class InspectorPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        minSize = NSSize(width: 280, height: 300)
        isReleasedWhenClosed = false

        let container = NSView(frame: contentRect)
        container.wantsLayer = true
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
