import Foundation
import AppKit

/// Wraps the idb CLI (Python client) + idb_companion for querying iOS Simulator UI hierarchy.
/// Manages companion server lifecycle — starts it before idb commands, stops it on cleanup.
@MainActor
final class IDBService: ObservableObject {
    @Published var idbCliPath: String?
    @Published var companionPath: String?
    @Published var isAvailable: Bool = false

    /// Currently running companion processes, keyed by device UDID.
    private var companions: [String: Process] = [:]

    init() {
        resolvePaths()
    }

    deinit {
        // Kill all companion processes
        for (_, process) in companions {
            process.terminate()
        }
    }

    /// Find both idb (Python CLI) and idb_companion on the system.
    func resolvePaths() {
        // Check UserDefaults first
        if let storedCli = UserDefaults.standard.string(forKey: "idbCliPath"),
           FileManager.default.isExecutableFile(atPath: storedCli),
           let storedCompanion = UserDefaults.standard.string(forKey: "idbCompanionPath"),
           FileManager.default.isExecutableFile(atPath: storedCompanion) {
            idbCliPath = storedCli
            companionPath = storedCompanion
            isAvailable = true
            return
        }

        // Find idb CLI (Python)
        let cliSearchPaths = [
            "\(home)/Library/Python/3.9/bin/idb",
            "\(home)/Library/Python/3.10/bin/idb",
            "\(home)/Library/Python/3.11/bin/idb",
            "\(home)/Library/Python/3.12/bin/idb",
            "\(home)/Library/Python/3.13/bin/idb",
            "/opt/homebrew/bin/idb",
            "/usr/local/bin/idb",
        ]

        let foundCli = ProcessRunner.which("idb") ?? cliSearchPaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }

        // Find idb_companion
        let companionSearchPaths = [
            "\(home)/idb-companion/bin/idb_companion",
            "/opt/homebrew/bin/idb_companion",
            "/usr/local/bin/idb_companion",
            "/usr/local/idb-companion/bin/idb_companion",
        ]

        let foundCompanion = ProcessRunner.which("idb_companion") ?? companionSearchPaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }

        if let cli = foundCli, let companion = foundCompanion {
            idbCliPath = cli
            companionPath = companion
            isAvailable = true
            UserDefaults.standard.set(cli, forKey: "idbCliPath")
            UserDefaults.standard.set(companion, forKey: "idbCompanionPath")
        } else {
            isAvailable = false
        }
    }

    private var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: - Companion Server Management

    /// Socket path for a given device.
    private func socketPath(for udid: String) -> String {
        "/tmp/idb/\(udid)_companion.sock"
    }

    /// Ensure the companion server is running for a device.
    /// If it's already running (socket exists and process alive), do nothing.
    func ensureCompanion(udid: String) async throws {
        // Check if our managed companion is still running
        if let process = companions[udid], process.isRunning {
            let sock = socketPath(for: udid)
            if FileManager.default.fileExists(atPath: sock) {
                return // Already running
            }
        }

        // Check if a socket already exists (started externally or from a previous run)
        let sock = socketPath(for: udid)
        if FileManager.default.fileExists(atPath: sock) {
            // Verify it's connectable by just leaving it — idb will fail if it's stale
            // Clean up stale socket
            try? FileManager.default.removeItem(atPath: sock)
        }

        guard let companion = companionPath else {
            throw IDBError.notInstalled
        }

        // Create /tmp/idb directory
        try FileManager.default.createDirectory(atPath: "/tmp/idb", withIntermediateDirectories: true)

        // Start companion as a long-running background process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: companion)
        process.arguments = ["--udid", udid, "--grpc-domain-sock", sock]

        // Set DYLD_FRAMEWORK_PATH for the companion's bundled frameworks
        let companionDir = (companion as NSString).deletingLastPathComponent
        let frameworksDir = ((companionDir as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("Frameworks")

        var env = ProcessInfo.processInfo.environment
        env["DYLD_FRAMEWORK_PATH"] = frameworksDir
        env["PATH"] = ProcessRunner.richPATH
        process.environment = env

        // Redirect output so it doesn't interfere
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        companions[udid] = process

        // Wait for the socket to appear (companion needs a moment to start)
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            if FileManager.default.fileExists(atPath: sock) {
                return
            }
        }

        throw IDBError.commandFailed("Companion server failed to start — socket not created after 6 seconds")
    }

    /// Stop the companion for a device.
    func stopCompanion(udid: String) {
        if let process = companions.removeValue(forKey: udid), process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(atPath: socketPath(for: udid))
    }

    // MARK: - Accessibility Hierarchy

    /// Fetch the full accessibility tree for a simulator.
    func describeAll(udid: String) async throws -> [ElementNode] {
        try await ensureCompanion(udid: udid)
        let output = try await runIDB(["ui", "describe-all", "--udid", udid, "--json", "--nested"])

        guard let data = output.data(using: .utf8) else {
            throw IDBError.invalidOutput
        }

        return try ElementNode.fromIDBJSON(data)
    }

    /// Hit-test at a specific iOS point.
    func describePoint(x: Double, y: Double, udid: String) async throws -> ElementNode? {
        try await ensureCompanion(udid: udid)
        let output = try await runIDB([
            "ui", "describe-point",
            String(Int(x)), String(Int(y)),
            "--udid", udid,
            "--json"
        ])

        guard let data = output.data(using: .utf8) else {
            throw IDBError.invalidOutput
        }

        return try ElementNode.fromIDBPointJSON(data)
    }

    /// Capture a screenshot from the simulator.
    func screenshot(udid: String) async throws -> NSImage {
        try await ensureCompanion(udid: udid)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("siminspector_\(UUID().uuidString).png")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try await runIDB(["screenshot", "--udid", udid, tempURL.path])

        guard let image = NSImage(contentsOf: tempURL) else {
            throw IDBError.screenshotFailed
        }

        return image
    }

    // MARK: - CLI Runner

    /// Run an idb CLI command. Companion must already be running.
    private func runIDB(_ arguments: [String]) async throws -> String {
        guard let cli = idbCliPath else {
            throw IDBError.notInstalled
        }

        let output = try await ProcessRunner.run(cli, arguments: arguments)

        guard output.exitCode == 0 else {
            let msg = output.stderr.isEmpty ? output.stdout : output.stderr
            throw IDBError.commandFailed(msg)
        }

        return output.stdout
    }

    // MARK: - Installation

    /// Install idb-companion via Homebrew and idb CLI via pip.
    func installViaHomebrew() async throws -> String {
        let brewPath = ProcessRunner.which("brew") ?? "/opt/homebrew/bin/brew"
        guard FileManager.default.isExecutableFile(atPath: brewPath) else {
            throw IDBError.homebrewNotFound
        }

        // Try brew install (may fail due to CLT version, so also try manual extract)
        let brewResult = try await ProcessRunner.run(brewPath, arguments: ["install", "idb-companion"])

        if brewResult.exitCode != 0 {
            // Try manual extraction from cached bottle
            let cacheResult = try await ProcessRunner.run(brewPath, arguments: ["--cache", "idb-companion"])
            let cachePath = cacheResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            if FileManager.default.fileExists(atPath: cachePath) {
                let extractDir = "\(home)/idb-companion"
                try? FileManager.default.removeItem(atPath: extractDir)
                try FileManager.default.createDirectory(atPath: extractDir, withIntermediateDirectories: true)

                let tarResult = try await ProcessRunner.run("/usr/bin/tar", arguments: [
                    "-xzf", cachePath,
                    "-C", extractDir,
                    "--strip-components=1"
                ])

                if tarResult.exitCode != 0 {
                    throw IDBError.installFailed("Failed to extract idb-companion: \(tarResult.stderr)")
                }
            } else {
                throw IDBError.installFailed(brewResult.stderr)
            }
        }

        // Install idb Python CLI
        let pip = ProcessRunner.which("pip3") ?? "/usr/bin/pip3"
        let pipResult = try await ProcessRunner.run(pip, arguments: ["install", "fb-idb"])
        if pipResult.exitCode != 0 {
            throw IDBError.installFailed("Failed to install fb-idb: \(pipResult.stderr)")
        }

        resolvePaths()

        if isAvailable {
            return "idb installed successfully."
        } else {
            throw IDBError.installFailed("Installation completed but binaries not found. Check your PATH.")
        }
    }

    /// Set paths manually.
    func setManualPaths(cliPath: String?, companionPath: String?) {
        if let cli = cliPath {
            self.idbCliPath = cli
            UserDefaults.standard.set(cli, forKey: "idbCliPath")
        }
        if let companion = companionPath {
            self.companionPath = companion
            UserDefaults.standard.set(companion, forKey: "idbCompanionPath")
        }
        isAvailable = (idbCliPath != nil && self.companionPath != nil)
    }

    enum IDBError: LocalizedError {
        case notInstalled
        case invalidOutput
        case screenshotFailed
        case homebrewNotFound
        case installFailed(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "idb is not installed. Install idb-companion (brew install idb-companion) and fb-idb (pip3 install fb-idb)."
            case .invalidOutput:
                return "Failed to parse idb output"
            case .screenshotFailed:
                return "Failed to capture screenshot"
            case .homebrewNotFound:
                return "Homebrew is not installed. Visit https://brew.sh to install it."
            case .installFailed(let msg):
                return "Installation failed: \(msg)"
            case .commandFailed(let msg):
                return "idb command failed: \(msg)"
            }
        }
    }
}
