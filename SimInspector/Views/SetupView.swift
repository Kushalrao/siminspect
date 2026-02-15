import SwiftUI

/// Setup sheet for installing idb CLI and idb-companion.
struct SetupView: View {
    @ObservedObject var idbService: IDBService
    @Environment(\.dismiss) private var dismiss
    @State private var isInstalling = false
    @State private var installLog = ""
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Setup Required")
                .font(.title)
                .fontWeight(.bold)

            Text("SimInspector needs **idb** (Facebook's iOS Device Bridge) to inspect Simulator UI elements. This includes two components:")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    label: "idb CLI (Python)",
                    found: idbService.idbCliPath != nil,
                    path: idbService.idbCliPath
                )
                statusRow(
                    label: "idb_companion",
                    found: idbService.companionPath != nil,
                    path: idbService.companionPath
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            if isInstalling {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Installing...")
                        .foregroundColor(.secondary)

                    if !installLog.isEmpty {
                        ScrollView {
                            Text(installLog)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 100)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                    }
                }
            } else if let error = installError {
                VStack(spacing: 8) {
                    Label("Installation failed", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 12) {
                Button("Install Automatically") {
                    install()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)

                Button("Set Paths Manually...") {
                    selectManualPaths()
                }
                .buttonStyle(.bordered)
                .disabled(isInstalling)
            }

            if idbService.isAvailable {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }

            Text("Manual install: `brew install idb-companion && pip3 install fb-idb`")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(40)
        .frame(width: 520)
    }

    @ViewBuilder
    private func statusRow(label: String, found: Bool, path: String?) -> some View {
        HStack {
            Image(systemName: found ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(found ? .green : .red)
            Text(label)
                .fontWeight(.medium)
            Spacer()
            if let path {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Not found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func install() {
        isInstalling = true
        installError = nil
        installLog = ""

        Task {
            do {
                let result = try await idbService.installViaHomebrew()
                installLog = result
                isInstalling = false
            } catch {
                installError = error.localizedDescription
                isInstalling = false
            }
        }
    }

    private func selectManualPaths() {
        let panel = NSOpenPanel()
        panel.title = "Select idb_companion binary"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "First, select the idb_companion binary"

        if panel.runModal() == .OK, let companionURL = panel.url {
            panel.title = "Select idb CLI binary"
            panel.message = "Now select the idb Python CLI binary"

            if panel.runModal() == .OK, let cliURL = panel.url {
                idbService.setManualPaths(cliPath: cliURL.path, companionPath: companionURL.path)
            }
        }
    }
}
