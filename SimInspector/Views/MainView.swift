import SwiftUI

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

/// Main split view with element tree and property inspector.
struct MainView: View {
    @StateObject private var simulatorService = SimulatorService()
    @StateObject private var idbService = IDBService()
    @StateObject private var windowTracker = WindowTracker()

    @State private var elements: [ElementNode] = []
    @State private var selectedElement: ElementNode?
    @State private var isInspectMode = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var showSetup = false

    // Overlay
    @State private var overlayWindow: OverlayWindow?
    @State private var hoveredElement: ElementNode?

    var body: some View {
        NavigationSplitView {
            ElementTreeView(
                elements: elements,
                selectedElement: $selectedElement,
                searchText: $searchText
            )
            .frame(minWidth: 300)
            .navigationSplitViewColumnWidth(min: 250, ideal: 350, max: 500)
        } detail: {
            PropertyInspectorView(element: selectedElement)
                .frame(minWidth: 250)
        }
        .toolbar {
            SimInspectorToolbar(
                simulatorService: simulatorService,
                isInspectMode: $isInspectMode,
                onRefresh: { Task { await refreshHierarchy() } }
            )
        }
        .overlay {
            if isLoading {
                ProgressView("Loading element tree...")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay(alignment: .bottom) {
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(error)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") { errorMessage = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
            }
        }
        .sheet(isPresented: $showSetup) {
            SetupView(idbService: idbService)
        }
        .task {
            await initialSetup()
        }
        .onChange(of: isInspectMode) { _, newValue in
            if newValue {
                startInspectMode()
            } else {
                stopInspectMode()
            }
        }
        .onChange(of: simulatorService.selectedDevice) { _, _ in
            Task { await refreshHierarchy() }
        }
        .onChange(of: selectedElement) { _, newElement in
            highlightSelectedElement(newElement)
        }
    }

    // MARK: - Setup

    private func initialSetup() async {
        // Check for idb
        if !idbService.isAvailable {
            showSetup = true
        }

        // Discover simulators and start polling for new ones
        await simulatorService.refreshDevices()
        simulatorService.startPolling()

        // Load hierarchy if we have a device
        if simulatorService.selectedDevice != nil {
            await refreshHierarchy()
        }
    }

    // MARK: - Hierarchy

    private func refreshHierarchy() async {
        guard let device = simulatorService.selectedDevice else {
            errorMessage = "No simulator selected"
            return
        }

        guard idbService.isAvailable else {
            showSetup = true
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            debugLog("[MainView] refreshHierarchy: calling describeAll for \(device.udid)")
            elements = try await idbService.describeAll(udid: device.udid)
            debugLog("[MainView] refreshHierarchy: got \(elements.count) elements, now calibrating")
            isLoading = false

            // Start tracking window and detect content area via Accessibility
            windowTracker.startTracking()
            try? await Task.sleep(nanoseconds: 200_000_000)
            detectContentArea()
        } catch {
            debugLog("[MainView] refreshHierarchy error: \(error)")
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    /// Detect the iOS content area within the Simulator window using Accessibility API.
    private func detectContentArea() {
        guard let root = elements.first else { return }
        let iOSSize = CGSize(width: root.frame.width, height: root.frame.height)

        // Use Accessibility API to find the device rendering area
        if let contentFrame = CoordinateMapper.detectSimulatorContentFrame() {
            debugLog("[MainView] AX detected content frame: \(contentFrame)")
            // contentFrame is the device view (includes bezel). iOS content is inside.
            // The device view renders the full device including bezel.
            // We need to figure out where the iOS screen sits within the device view.
            // The iOS screen occupies the device view minus bezel padding.
            // For now, use the device view frame and compute iOS content analytically:
            // the device aspect ratio from the view should match or be close to the iOS aspect.
            let viewAspect = contentFrame.width / contentFrame.height
            let iosAspect = iOSSize.width / iOSSize.height

            if abs(viewAspect - iosAspect) < 0.05 {
                // Close match — the device view IS the iOS content (no bezel or minimal bezel)
                debugLog("[MainView] Device view matches iOS aspect ratio — using as content rect")
                windowTracker.setCalibration(contentRect: contentFrame)
            } else {
                // Device view includes bezels — iOS content is centered within it, maintaining aspect ratio
                let scaleX = contentFrame.width / iOSSize.width
                let scaleY = contentFrame.height / iOSSize.height
                let scale = min(scaleX, scaleY)
                let contentW = iOSSize.width * scale
                let contentH = iOSSize.height * scale
                let contentX = contentFrame.origin.x + (contentFrame.width - contentW) / 2
                let contentY = contentFrame.origin.y + (contentFrame.height - contentH) / 2
                let contentRect = CGRect(x: contentX, y: contentY, width: contentW, height: contentH)
                debugLog("[MainView] Computed iOS content rect within device view: \(contentRect)")
                windowTracker.setCalibration(contentRect: contentRect)
            }
        } else {
            debugLog("[MainView] AX detection failed, using analytical fallback")
        }
    }

    // MARK: - Inspect Mode

    private func startInspectMode() {
        windowTracker.startTracking()

        // Reuse existing overlay or create new one
        let overlay = overlayWindow ?? OverlayWindow()
        overlay.ignoresMouseEvents = false
        overlay.orderFront(nil)
        overlayWindow = overlay

        // Position overlay over Simulator
        updateOverlayPosition()

        // Set up mouse tracking — local hit-testing, no async needed
        overlay.setMouseHandler { screenPoint in
            Task { @MainActor in
                self.handleMouseMove(screenPoint)
            }
        }

        overlay.setClickHandler { screenPoint in
            Task { @MainActor in
                self.handleMouseClick(screenPoint)
            }
        }

        // Start a timer to keep overlay positioned
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                if isInspectMode {
                    updateOverlayPosition()
                }
            }
        }
    }

    private func stopInspectMode() {
        if let selected = selectedElement {
            // Keep overlay showing the selected element
            overlayWindow?.ignoresMouseEvents = true
            overlayWindow?.setMouseHandler(nil)
            overlayWindow?.setClickHandler(nil)
            highlightSelectedElement(selected)
        } else {
            windowTracker.stopTracking()
            overlayWindow?.highlightRect(nil)
            overlayWindow?.orderOut(nil)
            overlayWindow = nil
        }
    }

    private func updateOverlayPosition() {
        guard let frame = windowTracker.simulatorWindowFrame else { return }
        overlayWindow?.updateFrame(to: frame)
    }

    /// Build a CoordinateMapper using known window frame and iOS device size.
    private func currentMapper() -> CoordinateMapper? {
        guard let windowFrame = windowTracker.simulatorWindowFrame else { return nil }
        guard let root = elements.first else { return nil }
        let iOSSize = CGSize(width: root.frame.width, height: root.frame.height)

        // Use calibrated data if available
        if windowTracker.isCalibrated, let contentRect = windowTracker.contentRect {
            return CoordinateMapper(contentRect: contentRect, deviceSize: iOSSize)
        }

        // Analytical: title bar is 28pt, iOS content fills remaining space maintaining aspect ratio
        let titleBarHeight: CGFloat = 28
        let availableWidth = windowFrame.width
        let availableHeight = windowFrame.height - titleBarHeight

        let scaleX = availableWidth / iOSSize.width
        let scaleY = availableHeight / iOSSize.height
        let scale = min(scaleX, scaleY)

        let contentWidth = iOSSize.width * scale
        let contentHeight = iOSSize.height * scale

        let contentX = windowFrame.origin.x + (availableWidth - contentWidth) / 2
        let contentY = windowFrame.origin.y + titleBarHeight + (availableHeight - contentHeight) / 2

        let contentRect = CGRect(x: contentX, y: contentY, width: contentWidth, height: contentHeight)
        debugLog("[currentMapper] analytical contentRect=\(contentRect), scale=\(scale), windowFrame=\(windowFrame)")
        return CoordinateMapper(contentRect: contentRect, deviceSize: iOSSize)
    }

    private func handleMouseMove(_ screenPoint: NSPoint) {
        guard let mapper = currentMapper() else { return }

        // Convert screen point to top-left origin for the mapper
        guard let screen = NSScreen.main else { return }
        let topLeftPoint = CGPoint(
            x: screenPoint.x,
            y: screen.frame.height - screenPoint.y
        )

        guard let iosPoint = mapper.macScreenToiOS(topLeftPoint) else {
            overlayWindow?.highlightRect(nil)
            hoveredElement = nil
            return
        }

        // Local hit-test against the cached element tree — instant, no IPC
        var hit: ElementNode?
        for root in elements {
            if let found = root.hitTest(point: iosPoint) {
                hit = found
                break
            }
        }

        if let hit {
            let screenRect = mapper.iOSFrameToScreen(hit.frame.cgRect)
            overlayWindow?.highlightRect(screenRect)
            overlayWindow?.showLabel(hit.displayTitle)
            hoveredElement = hit
        } else {
            overlayWindow?.highlightRect(nil)
            hoveredElement = nil
        }
    }

    private func handleMouseClick(_ screenPoint: NSPoint) {
        // Just select whatever is currently hovered — already computed by handleMouseMove
        if let element = hoveredElement {
            selectedElement = element
            isInspectMode = false
        }
    }

    // MARK: - Selection Highlight

    private func highlightSelectedElement(_ element: ElementNode?) {
        guard let element else {
            // Clear highlight if nothing selected and not in inspect mode
            if !isInspectMode {
                overlayWindow?.highlightRect(nil)
                overlayWindow?.orderOut(nil)
            }
            return
        }

        // Ensure window tracker is running so we know where the Simulator is
        windowTracker.startTracking()
        guard let mapper = currentMapper() else { return }

        let screenRect = mapper.iOSFrameToScreen(element.frame.cgRect)

        // Create or reuse overlay
        if overlayWindow == nil {
            let overlay = OverlayWindow()
            overlayWindow = overlay
        }

        if let frame = windowTracker.simulatorWindowFrame {
            overlayWindow?.updateFrame(to: frame)
        }
        overlayWindow?.orderFront(nil)
        overlayWindow?.highlightRect(screenRect)
        overlayWindow?.showLabel(element.displayTitle)

        // Keep overlay positioned while selection is shown
        if !isInspectMode {
            overlayWindow?.ignoresMouseEvents = true
        }
    }
}
