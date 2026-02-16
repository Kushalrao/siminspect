import SwiftUI
import AppKit

private struct BlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.layer?.cornerRadius = cornerRadius
    }
}

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

struct MainView: View {
    @StateObject private var simulatorService = SimulatorService()
    @StateObject private var idbService = IDBService()
    @EnvironmentObject var windowTracker: WindowTracker

    @State private var elements: [ElementNode] = []
    @State private var selectedElement: ElementNode?
    @State private var isInspectMode = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var showSetup = false
    @State private var showSearch = false

    @State private var overlayWindow: OverlayWindow?
    @State private var hoveredElement: ElementNode?
    @State private var recalibrationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Spacer()

                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showSearch.toggle() } }) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: { isInspectMode.toggle() }) {
                    Image(systemName: "cursorarrow.click")
                        .font(.caption)
                        .foregroundColor(isInspectMode ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button(action: { Task { await refreshHierarchy() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search (togglable)
            if showSearch {
                HStack(spacing: 4) {
                    TextField("Search...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            // Sim picker (compact)
            if simulatorService.bootedDevices.count > 1 {
                Picker("", selection: $simulatorService.selectedDevice) {
                    ForEach(simulatorService.bootedDevices) { device in
                        Text(device.displayName).tag(device as SimulatorDevice?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.caption2)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }

            // Content
            if isLoading {
                Spacer()
                ProgressView()
                    .scaleEffect(0.7)
                Spacer()
            } else if elements.isEmpty {
                Spacer()
                Text("No elements")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.6))
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(flattenedElements) { item in
                                elementRow(item, proxy: proxy)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }

            }
        }
        .overlay(alignment: .bottom) {
            if let error = errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.yellow)
                    .lineLimit(2)
                    .padding(6)
                    .onTapGesture { errorMessage = nil }
            }
        }
        .sheet(isPresented: $showSetup) {
            SetupView(idbService: idbService)
        }
        .task { await initialSetup() }
        .onChange(of: isInspectMode) { _, v in
            if v { startInspectMode() } else { stopInspectMode() }
        }
        .onChange(of: simulatorService.selectedDevice) { _, _ in
            Task { await refreshHierarchy() }
        }
        .onChange(of: selectedElement) { _, el in highlightSelectedElement(el) }
        .onChange(of: windowTracker.simulatorWindowFrame) { _, _ in
            if isInspectMode || selectedElement != nil { updateOverlayPosition() }
            if !windowTracker.isCalibrated && !elements.isEmpty {
                recalibrationTask?.cancel()
                recalibrationTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if !Task.isCancelled {
                        detectContentArea()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .background(.clear)
    }

    // MARK: - Flattened tree for display

    private struct FlatItem: Identifiable {
        let id: UUID
        let node: ElementNode
        let depth: Int
        let hasChildren: Bool
    }

    private var flattenedElements: [FlatItem] {
        var result: [FlatItem] = []
        func walk(_ nodes: [ElementNode], depth: Int) {
            for node in nodes {
                let matches = searchText.isEmpty
                    || node.type.localizedCaseInsensitiveContains(searchText)
                    || (node.label?.localizedCaseInsensitiveContains(searchText) ?? false)
                if matches || !node.children.isEmpty {
                    result.append(FlatItem(id: node.id, node: node, depth: depth, hasChildren: !node.children.isEmpty))
                    walk(node.children, depth: depth + 1)
                }
            }
        }
        walk(elements, depth: 0)
        return result
    }

    @ViewBuilder
    private func elementRow(_ item: FlatItem, proxy: ScrollViewProxy) -> some View {
        let isSelected = selectedElement?.id == item.id

        HStack(spacing: 0) {
            // Indent
            Spacer()
                .frame(width: CGFloat(item.depth) * 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.node.type)
                    .font(.system(size: 14, weight: isSelected ? .bold : .medium, design: .default))
                    .foregroundColor(.black)
                    .lineLimit(1)

                if let label = item.node.label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 14, weight: .regular, design: .default))
                        .foregroundColor(.black.opacity(0.5))
                        .lineLimit(1)
                }

                if isSelected {
                    Divider().opacity(0.15).padding(.vertical, 2)

                    Text("\(Int(item.node.frame.x)), \(Int(item.node.frame.y))  \(Int(item.node.frame.width))×\(Int(item.node.frame.height))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.black.opacity(0.45))

                    if let role = item.node.role, !role.isEmpty {
                        Text(role)
                            .font(.system(size: 11))
                            .foregroundColor(.black.opacity(0.45))
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            ZStack {
                BlurView(material: .popover, cornerRadius: 14)
                Color.white.opacity(0.06)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                if isSelected {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white)
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedElement = item.node
        }
    }

    // MARK: - Setup & Hierarchy

    private func initialSetup() async {
        if !idbService.isAvailable { showSetup = true }
        await simulatorService.refreshDevices()
        simulatorService.startPolling()
        if simulatorService.selectedDevice != nil { await refreshHierarchy() }
    }

    private func refreshHierarchy() async {
        guard let device = simulatorService.selectedDevice else {
            errorMessage = "No simulator selected"; return
        }
        guard idbService.isAvailable else { showSetup = true; return }
        isLoading = true; errorMessage = nil
        do {
            elements = try await idbService.describeAll(udid: device.udid)
            isLoading = false
            windowTracker.startTracking()
            try? await Task.sleep(nanoseconds: 200_000_000)
            detectContentArea()
        } catch {
            isLoading = false; errorMessage = error.localizedDescription
        }
    }

    private func detectContentArea() {
        guard let root = elements.first else { return }
        let iOSSize = CGSize(width: root.frame.width, height: root.frame.height)
        if let contentFrame = CoordinateMapper.detectSimulatorContentFrame() {
            let viewAspect = contentFrame.width / contentFrame.height
            let iosAspect = iOSSize.width / iOSSize.height
            if abs(viewAspect - iosAspect) < 0.05 {
                windowTracker.setCalibration(contentRect: contentFrame)
            } else {
                let scale = min(contentFrame.width / iOSSize.width, contentFrame.height / iOSSize.height)
                let cw = iOSSize.width * scale, ch = iOSSize.height * scale
                let cx = contentFrame.origin.x + (contentFrame.width - cw) / 2
                let cy = contentFrame.origin.y + (contentFrame.height - ch) / 2
                windowTracker.setCalibration(contentRect: CGRect(x: cx, y: cy, width: cw, height: ch))
            }
        }
    }

    // MARK: - Inspect Mode

    private func startInspectMode() {
        windowTracker.startTracking()
        let overlay = overlayWindow ?? OverlayWindow()
        overlay.ignoresMouseEvents = false
        overlay.orderFront(nil)
        overlayWindow = overlay
        updateOverlayPosition()
        overlay.setMouseHandler { sp in Task { @MainActor in self.handleMouseMove(sp) } }
        overlay.setClickHandler { sp in Task { @MainActor in self.handleMouseClick(sp) } }
    }

    private func stopInspectMode() {
        if let selected = selectedElement {
            overlayWindow?.ignoresMouseEvents = true
            overlayWindow?.setMouseHandler(nil)
            overlayWindow?.setClickHandler(nil)
            highlightSelectedElement(selected)
        } else {
            overlayWindow?.highlightRect(nil)
            overlayWindow?.orderOut(nil)
            overlayWindow = nil
        }
    }

    private func updateOverlayPosition() {
        guard let frame = windowTracker.simulatorWindowFrame else { return }
        overlayWindow?.updateFrame(to: frame)
    }

    private func currentMapper() -> CoordinateMapper? {
        guard let wf = windowTracker.simulatorWindowFrame, let root = elements.first else { return nil }
        let ios = CGSize(width: root.frame.width, height: root.frame.height)
        if windowTracker.isCalibrated, let cr = windowTracker.contentRect {
            return CoordinateMapper(contentRect: cr, deviceSize: ios)
        }
        let tbh: CGFloat = 28
        let aw = wf.width, ah = wf.height - tbh
        let scale = min(aw / ios.width, ah / ios.height)
        let cw = ios.width * scale, ch = ios.height * scale
        let cx = wf.origin.x + (aw - cw) / 2, cy = wf.origin.y + tbh + (ah - ch) / 2
        return CoordinateMapper(contentRect: CGRect(x: cx, y: cy, width: cw, height: ch), deviceSize: ios)
    }

    private func handleMouseMove(_ screenPoint: NSPoint) {
        guard let mapper = currentMapper(), let screen = NSScreen.main else { return }
        let tlp = CGPoint(x: screenPoint.x, y: screen.frame.height - screenPoint.y)
        guard let ip = mapper.macScreenToiOS(tlp) else {
            overlayWindow?.highlightRect(nil); hoveredElement = nil; return
        }
        var hit: ElementNode?
        for r in elements { if let f = r.hitTest(point: ip) { hit = f; break } }
        if let hit {
            overlayWindow?.highlightRect(mapper.iOSFrameToScreen(hit.frame.cgRect))
            overlayWindow?.showLabel(hit.displayTitle)
            hoveredElement = hit
        } else {
            overlayWindow?.highlightRect(nil); hoveredElement = nil
        }
    }

    private func handleMouseClick(_ screenPoint: NSPoint) {
        if let el = hoveredElement { selectedElement = el; isInspectMode = false }
    }

    private func highlightSelectedElement(_ element: ElementNode?) {
        guard let element else {
            if !isInspectMode { overlayWindow?.highlightRect(nil); overlayWindow?.orderOut(nil) }
            return
        }
        windowTracker.startTracking()
        guard let mapper = currentMapper() else { return }
        if overlayWindow == nil { overlayWindow = OverlayWindow() }
        if let frame = windowTracker.simulatorWindowFrame { overlayWindow?.updateFrame(to: frame) }
        overlayWindow?.orderFront(nil)
        overlayWindow?.highlightRect(mapper.iOSFrameToScreen(element.frame.cgRect))
        overlayWindow?.showLabel(element.displayTitle)
        if !isInspectMode { overlayWindow?.ignoresMouseEvents = true }
    }
}
