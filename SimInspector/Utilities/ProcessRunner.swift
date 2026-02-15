import Foundation

/// Async wrapper around Process for running CLI commands and capturing output.
struct ProcessRunner {
    struct Output {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    enum RunError: LocalizedError {
        case commandFailed(exitCode: Int32, stderr: String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let code, let stderr):
                return "Command failed (exit \(code)): \(stderr)"
            case .notFound(let cmd):
                return "Command not found: \(cmd)"
            }
        }
    }

    /// A rich PATH that covers common tool locations (GUI apps have a minimal PATH).
    static var richPATH: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "\(home)/Library/Python/3.9/bin",
            "\(home)/Library/Python/3.10/bin",
            "\(home)/Library/Python/3.11/bin",
            "\(home)/Library/Python/3.12/bin",
            "\(home)/Library/Python/3.13/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/Applications/Xcode.app/Contents/Developer/usr/bin",
        ]
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let allPaths = paths + existing.split(separator: ":").map(String.init)
        var seen = Set<String>()
        return allPaths.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Run a command and return its output.
    /// Reads stdout/stderr concurrently to avoid pipe buffer deadlocks.
    static func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        // Always start with a rich environment so child processes can find tools
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = richPATH
        if let environment {
            env.merge(environment) { _, new in new }
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read pipe data on background threads BEFORE waiting for termination.
        // This prevents deadlock when the child fills the pipe buffer.
        var stdoutData = Data()
        var stderrData = Data()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        return try await withCheckedThrowingContinuation { continuation in
            // Collect stdout on a background queue
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stdoutData = stdoutHandle.readDataToEndOfFile()
                group.leave()
            }

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stderrData = stderrHandle.readDataToEndOfFile()
                group.leave()
            }

            process.terminationHandler = { proc in
                // Wait for both reads to complete
                group.wait()

                let output = Output(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: proc.terminationStatus
                )
                continuation.resume(returning: output)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Run a command expecting success (exit code 0). Throws on failure.
    static func runChecked(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> String {
        let output = try await run(executable, arguments: arguments, environment: environment)
        guard output.exitCode == 0 else {
            throw RunError.commandFailed(exitCode: output.exitCode, stderr: output.stderr)
        }
        return output.stdout
    }

    /// Find an executable in common paths.
    static func which(_ command: String) -> String? {
        let searchPaths = [
            "/usr/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
        ]

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pythonPaths = [
            "\(home)/Library/Python/3.9/bin",
            "\(home)/Library/Python/3.10/bin",
            "\(home)/Library/Python/3.11/bin",
            "\(home)/Library/Python/3.12/bin",
            "\(home)/Library/Python/3.13/bin",
        ]

        // Check PATH first
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for dir in pathDirs + searchPaths + pythonPaths {
            let fullPath = (dir as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }
}
