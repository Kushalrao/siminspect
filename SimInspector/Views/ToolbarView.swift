import SwiftUI

/// Toolbar content for the main window.
struct SimInspectorToolbar: ToolbarContent {
    @ObservedObject var simulatorService: SimulatorService
    @Binding var isInspectMode: Bool
    let onRefresh: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Simulator picker
            Picker("Simulator", selection: $simulatorService.selectedDevice) {
                if simulatorService.bootedDevices.isEmpty {
                    Text("No Simulators").tag(nil as SimulatorDevice?)
                }
                ForEach(simulatorService.bootedDevices) { device in
                    Text(device.displayName).tag(device as SimulatorDevice?)
                }
            }
            .frame(minWidth: 200)

            Divider()

            // Inspect mode toggle
            Button(action: { isInspectMode.toggle() }) {
                Label(
                    isInspectMode ? "Stop Inspecting" : "Inspect Element",
                    systemImage: isInspectMode ? "cursorarrow.click.badge.clock" : "cursorarrow.click"
                )
            }
            .help("Toggle inspect mode (⌘⇧I)")
            .keyboardShortcut("i", modifiers: [.command, .shift])

            // Refresh
            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh element tree (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
