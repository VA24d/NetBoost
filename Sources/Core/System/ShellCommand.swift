import Foundation

public struct ShellOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let duration: TimeInterval

    public init(stdout: String, stderr: String, exitCode: Int32, duration: TimeInterval = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.duration = duration
    }

    public var succeeded: Bool {
        exitCode == 0
    }
}

public enum ShellError: Error, LocalizedError, Sendable, Equatable {
    case commandNotFound(String)
    case executionFailed(exitCode: Int32, stdout: String, stderr: String)
    case timedOut(timeout: TimeInterval)
    case processError(String)

    public var errorDescription: String? {
        switch self {
        case .commandNotFound(let cmd):
            return "Command not found: \(cmd)"
        case .executionFailed(let code, _, let err):
            return "Command failed with exit code \(code): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .timedOut(let timeout):
            return "Command timed out after \(timeout) seconds"
        case .processError(let msg):
            return "Process error: \(msg)"
        }
    }
}

public final class ShellCommand: Sendable {

    /// Runs an executable with arguments and enforces a timeout.
    public static func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30.0
    ) async throws -> ShellOutput {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Resolve executable path if simple command name
        let resolvedExecutable: String
        if executable.hasPrefix("/") {
            resolvedExecutable = executable
        } else if let found = resolvePath(for: executable) {
            resolvedExecutable = found
        } else {
            resolvedExecutable = "/usr/bin/env"
            var fullArgs = [executable]
            fullArgs.append(contentsOf: arguments)
            return try await run(resolvedExecutable, arguments: fullArgs, environment: environment, timeout: timeout)
        }

        process.executableURL = URL(fileURLWithPath: resolvedExecutable)
        process.arguments = arguments

        if let env = environment {
            var fullEnv = ProcessInfo.processInfo.environment
            for (k, v) in env {
                fullEnv[k] = v
            }
            process.environment = fullEnv
        }

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startTime = Date()

        do {
            try process.run()
        } catch {
            throw ShellError.processError(error.localizedDescription)
        }

        // Handle timeout using cooperative async task
        return try await withThrowingTaskGroup(of: ShellOutput.self) { group in
            // Task 1: Wait for process termination and collect pipes
            group.addTask {
                process.waitUntilExit()
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                let duration = Date().timeIntervalSince(startTime)

                return ShellOutput(
                    stdout: stdoutStr,
                    stderr: stderrStr,
                    exitCode: process.terminationStatus,
                    duration: duration
                )
            }

            // Task 2: Timeout watchdog
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                }
                throw ShellError.timedOut(timeout: timeout)
            }

            // Await the first finished task
            guard let result = try await group.next() else {
                throw ShellError.processError("Process failed to yield output")
            }

            group.cancelAll()
            return result
        }
    }

    /// Convenience runner executing through /bin/bash -c "..."
    public static func runBash(
        _ script: String,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30.0
    ) async throws -> ShellOutput {
        try await run("/bin/bash", arguments: ["-c", script], environment: environment, timeout: timeout)
    }

    private static func resolvePath(for command: String) -> String? {
        let standardPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
        for dir in standardPaths {
            let fullPath = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }
}
