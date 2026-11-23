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

public final class PrivilegeHelper: @unchecked Sendable {

    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _isAuthorized: Bool = false
    nonisolated(unsafe) private static var _sessionToken: String? = nil
    nonisolated(unsafe) private static var _sessionExpiry: Date? = nil

    /// Checks if the current process is running with root privileges (EUID == 0).
    public static var isRoot: Bool {
        geteuid() == 0
    }

    /// Whether NetBoost currently holds an active, authorized administrative session (or EUID == 0).
    public static var isAuthorized: Bool {
        if isRoot { return true }
        return sessionLock.withLock {
            if let expiry = _sessionExpiry, expiry < Date() {
                _isAuthorized = false
                _sessionToken = nil
                return false
            }
            return _isAuthorized
        }
    }

    /// Current session token if authorized.
    public static var sessionToken: String? {
        sessionLock.withLock { _sessionToken }
    }

    /// Explicitly requests upfront authorization from the user, establishing a persistent privileged session.
    @discardableResult
    public static func requestAuthorization(
        reason: String = "NetBoost requires administrator privileges to configure network adapters and packet filter routing."
    ) async throws -> Bool {
        if isRoot {
            sessionLock.withLock {
                _isAuthorized = true
                _sessionToken = "root-\(ProcessInfo.processInfo.processIdentifier)"
                _sessionExpiry = Date.distantFuture
            }
            return true
        }

        if isAuthorized {
            return true
        }

        let validationScript = "echo 'NetBoost privileged session active'"
        let output = try await runElevated(script: validationScript)
        if output.succeeded {
            sessionLock.withLock {
                _isAuthorized = true
                _sessionToken = UUID().uuidString
                _sessionExpiry = Date().addingTimeInterval(3600)
            }
            return true
        } else {
            throw PrivilegeError.executionFailed(output.stderr)
        }
    }

    /// Revokes cached authorization and resets the session.
    public static func revokeAuthorization() {
        sessionLock.withLock {
            _isAuthorized = false
            _sessionToken = nil
            _sessionExpiry = nil
        }
    }

    /// Manually sets authorization state for testing environments.
    public static func setAuthorizedForTesting(_ authorized: Bool) {
        sessionLock.withLock {
            _isAuthorized = authorized
            _sessionToken = authorized ? "test-token" : nil
            _sessionExpiry = authorized ? Date().addingTimeInterval(3600) : nil
        }
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

        do {
            let handled = try handleElevationResult(output)
            sessionLock.withLock {
                _isAuthorized = true
                _sessionToken = UUID().uuidString
                _sessionExpiry = Date().addingTimeInterval(3600)
            }
            return handled
        } catch PrivilegeError.elevationDenied {
            sessionLock.withLock {
                _isAuthorized = false
                _sessionToken = nil
                _sessionExpiry = nil
            }
            throw PrivilegeError.elevationDenied
        }
    }

    /// Executes an array of shell commands in a single atomic script ('cmd1 && cmd2 && ...')
    /// ensuring only a single upfront authorization prompt is presented.
    public static func runBatchElevated(
        commands: [String],
        timeout: TimeInterval = 60.0
    ) async throws -> ShellOutput {
        guard !commands.isEmpty else {
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        let combined = commands.joined(separator: " && ")
        return try await runElevated(script: combined, timeout: timeout)
    }

    /// Evaluates the ShellOutput from an elevation attempt, throwing PrivilegeError if execution failed or elevation was denied.
    public static func handleElevationResult(_ output: ShellOutput) throws -> ShellOutput {
        if !output.succeeded {
            let err = output.stderr
            if err.contains("User canceled") || err.contains("-128") || err.contains("Authentication dialog dismissed") {
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
