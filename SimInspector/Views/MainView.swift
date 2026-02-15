import SwiftUI

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
    }

    // MARK: - Setup

    private func initialSetup() async {
        // Check for idb-companion
        if !idbService.isAvailable {
            showSetup = true
        }

        // Discover simulators
        await simulatorService.refreshDevices()

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
            elements = try await idbService.describeAll(udid: device.udid)
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Inspect Mode

    private func startInspectMode() {
        windowTracker.startTracking()

        let overlay = OverlayWindow()
        overlay.orderFront(nil)
        overlayWindow = overlay

        // Position overlay over Simulator
        updateOverlayPosition()

        // Set up mouse tracking
        overlay.setMouseHandler { [self] screenPoint in
            Task { @MainActor in
                await handleMouseMove(screenPoint)
            }
        }

        overlay.setClickHandler { [self] screenPoint in
            Task { @MainActor in
                await handleMouseClick(screenPoint)
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
        windowTracker.stopTracking()
        overlayWindow?.highlightRect(nil)
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }

    private func updateOverlayPosition() {
        guard let frame = windowTracker.simulatorWindowFrame else { return }
        overlayWindow?.updateFrame(to: frame)
    }

    private func handleMouseMove(_ screenPoint: NSPoint) async {
        guard let device = simulatorService.selectedDevice,
              let contentRect = windowTracker.contentRect else { return }

        // Convert screen point to top-left origin for the mapper
        guard let screen = NSScreen.main else { return }
        let topLeftPoint = CGPoint(
            x: screenPoint.x,
            y: screen.frame.height - screenPoint.y
        )

        let mapper = CoordinateMapper.autoDetect(contentRect: contentRect)
        guard let iosPoint = mapper.macScreenToiOS(topLeftPoint) else {
            overlayWindow?.highlightRect(nil)
            return
        }

        do {
            if let element = try await idbService.describePoint(
                x: iosPoint.x, y: iosPoint.y, udid: device.udid
            ) {
                let screenRect = mapper.iOSFrameToScreen(element.frame.cgRect)
                overlayWindow?.highlightRect(screenRect)
            } else {
                overlayWindow?.highlightRect(nil)
            }
        } catch {
            overlayWindow?.highlightRect(nil)
        }
    }

    private func handleMouseClick(_ screenPoint: NSPoint) async {
        guard let device = simulatorService.selectedDevice,
              let contentRect = windowTracker.contentRect else { return }

        guard let screen = NSScreen.main else { return }
        let topLeftPoint = CGPoint(
            x: screenPoint.x,
            y: screen.frame.height - screenPoint.y
        )

        let mapper = CoordinateMapper.autoDetect(contentRect: contentRect)
        guard let iosPoint = mapper.macScreenToiOS(topLeftPoint) else { return }

        do {
            if let element = try await idbService.describePoint(
                x: iosPoint.x, y: iosPoint.y, udid: device.udid
            ) {
                selectedElement = element
                // Find and select in tree
                isInspectMode = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
