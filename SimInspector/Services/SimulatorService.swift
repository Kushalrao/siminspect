import Foundation

/// Discovers booted iOS Simulators via `xcrun simctl`.
@MainActor
final class SimulatorService: ObservableObject {
    @Published var bootedDevices: [SimulatorDevice] = []
    @Published var selectedDevice: SimulatorDevice?
    @Published var error: String?

    private let xcrunPath: String

    init() {
        self.xcrunPath = ProcessRunner.which("xcrun") ?? "/usr/bin/xcrun"
    }

    /// Refresh the list of booted simulators.
    func refreshDevices() async {
        do {
            let output = try await ProcessRunner.runChecked(
                xcrunPath,
                arguments: ["simctl", "list", "devices", "booted", "--json"]
            )

            guard let data = output.data(using: .utf8) else {
                error = "Failed to read simctl output"
                return
            }

            let response = try JSONDecoder().decode(SimctlDevicesResponse.self, from: data)

            var devices: [SimulatorDevice] = []
            for (runtime, simDevices) in response.devices {
                for device in simDevices where device.isBooted {
                    devices.append(SimulatorDevice(
                        udid: device.udid,
                        name: device.name,
                        state: device.state,
                        runtime: runtime,
                        deviceTypeIdentifier: device.deviceTypeIdentifier
                    ))
                }
            }

            self.bootedDevices = devices.sorted { $0.name < $1.name }
            self.error = nil

            // Auto-select first device if nothing selected or selection went away
            if selectedDevice == nil || !devices.contains(where: { $0.udid == selectedDevice?.udid }) {
                selectedDevice = devices.first
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
