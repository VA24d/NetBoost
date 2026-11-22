import Foundation
import Darwin

public enum PrivilegeError: Error, LocalizedError, Sendable, Equatable {
    case elevationDenied
    case helperNotFound(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .elevationDenied:
            return "Administrator privilege elevation was denied or cancelled."
        case .helperNotFound(let path):
            return "Privileged helper script not found at path: \(path)"
        case .executionFailed(let msg):
            return "Privileged command failed: \(msg)"
        }
    }
}

public final class PrivilegeHelper: Sendable {

    /// Checks if the current process is running with root privileges (EUID == 0).
    public static var isRoot: Bool {
        geteuid() == 0
    }

    /// Locates the netboost-helper.sh script.
    public static func locateHelperScript() -> String? {
        let candidatePaths = [
            // Current working directory / Scripts
            FileManager.default.currentDirectoryPath + "/Scripts/netboost-helper.sh",
            // Relative to main bundle Resources
            Bundle.main.resourcePath.map { $0 + "/netboost-helper.sh" },
            Bundle.main.resourcePath.map { $0 + "/Scripts/netboost-helper.sh" },
            // Standard system install locations
            "/usr/local/bin/netboost-helper.sh",
            "/opt/netboost/bin/netboost-helper.sh"
        ].compactMap { $0 }

        for path in candidatePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Executes a command with root privileges. If already root, executes directly.
    /// If not root, prompts user via macOS AppleScript administrator elevation dialog.
    public static func runElevated(
        script: String,
        arguments: [String] = [],
        timeout: TimeInterval = 60.0
    ) async throws -> ShellOutput {
        let fullCommand: String
        if arguments.isEmpty {
            fullCommand = script
        } else {
            let quotedArgs = arguments.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            fullCommand = "\(script) \(quotedArgs.joined(separator: " "))"
        }

        if isRoot {
            // Already root, execute directly through shell
            return try await ShellCommand.runBash(fullCommand, timeout: timeout)
        }

        // Escape double quotes and backslashes for AppleScript do shell script
        let escapedScript = fullCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = "do shell script \"\(escapedScript)\" with administrator privileges"

        let output = try await ShellCommand.run(
            "/usr/bin/osascript",
            arguments: ["-e", appleScript],
            timeout: timeout
        )

        return try handleElevationResult(output)
    }

    /// Evaluates the ShellOutput from an elevation attempt, throwing PrivilegeError if execution failed or elevation was denied.
    static func handleElevationResult(_ output: ShellOutput) throws -> ShellOutput {
        if !output.succeeded {
            if output.stderr.contains("User canceled") || output.exitCode == 1 {
                throw PrivilegeError.elevationDenied
            }
            throw PrivilegeError.executionFailed(output.stderr)
        }
        return output
    }

    /// Runs an action via the netboost-helper.sh script with root privileges.
    public static func runHelper(
        action: String,
        arguments: [String] = [],
        timeout: TimeInterval = 60.0
    ) async throws -> ShellOutput {
        guard let helperPath = locateHelperScript() else {
            throw PrivilegeError.helperNotFound("Scripts/netboost-helper.sh")
        }

        var fullArgs = [action]
        fullArgs.append(contentsOf: arguments)

        return try await runElevated(
            script: helperPath,
            arguments: fullArgs,
            timeout: timeout
        )
    }
}
