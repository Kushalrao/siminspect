import Foundation

/// Represents a booted iOS Simulator device.
struct SimulatorDevice: Identifiable, Hashable, Codable {
    let udid: String
    let name: String
    let state: String
    let runtime: String
    let deviceTypeIdentifier: String?

    var id: String { udid }

    var displayName: String {
        let runtimeVersion = runtime
            .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .replacingOccurrences(of: "-", with: ".")
            .replacingOccurrences(of: "iOS.", with: "iOS ")
        return "\(name) (\(runtimeVersion))"
    }

    var isBooted: Bool {
        state == "Booted"
    }
}

// MARK: - simctl JSON parsing

/// Root response from `xcrun simctl list devices --json`
struct SimctlDevicesResponse: Codable {
    let devices: [String: [SimctlDevice]]
}

struct SimctlDevice: Codable {
    let name: String
    let udid: String
    let state: String
    let deviceTypeIdentifier: String?

    var isBooted: Bool { state == "Booted" }
}
