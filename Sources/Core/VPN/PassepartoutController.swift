import Foundation

// MARK: - Command Running Protocol

/// Abstract command runner for executing shell commands, allowing deterministic mocking.
public protocol CommandRunning: Sendable {
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> ShellOutput
}

/// Production command runner executing via ShellCommand.run.
public struct DefaultCommandRunner: CommandRunning {
    public init() {}

    public func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30.0
    ) async throws -> ShellOutput {
        try await ShellCommand.run(executable, arguments: arguments, environment: environment, timeout: timeout)
    }
}

/// Mock command runner executing via a test-provided closure.
public struct MockCommandRunner: CommandRunning {
    public typealias Handler = @Sendable (String, [String]) async throws -> ShellOutput
    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30.0
    ) async throws -> ShellOutput {
        try await handler(executable, arguments)
    }
}

// MARK: - Controller Errors

public enum VPNControllerError: Error, LocalizedError, Sendable, Equatable {
    case profileNotFound(String)
    case commandFailed(exitCode: Int32, message: String)
    case connectionTimeout(profileName: String)

    public var errorDescription: String? {
        switch self {
        case .profileNotFound(let p):
            return "VPN Profile not found: \(p)"
        case .commandFailed(let c, let msg):
            return "scutil command failed (exit code \(c)): \(msg)"
        case .connectionTimeout(let p):
            return "Timed out connecting to VPN profile: \(p)"
        }
    }
}

// MARK: - Passepartout Controller

/// Unprivileged macOS system VPN controller managing Passepartout profiles via /usr/sbin/scutil --nc.
public final class PassepartoutController: VPNControllerProtocol, @unchecked Sendable {
    public static let scutilPath = "/usr/sbin/scutil"
    public static let defaultProfileName = "macos.ovpn"

    private let runner: CommandRunning
    private let lock = NSLock()
    private var cachedProfiles: [VPNServiceProfile] = []

    public init(runner: CommandRunning = DefaultCommandRunner()) {
        self.runner = runner
    }

    // MARK: - Command Generators

    public static func makeStatusCommand(profile: String) -> [String] {
        [scutilPath, "--nc", "status", profile]
    }

    public static func makeStartCommand(profile: String) -> [String] {
        [scutilPath, "--nc", "start", profile]
    }

    public static func makeStopCommand(profile: String) -> [String] {
        [scutilPath, "--nc", "stop", profile]
    }

    public static func makeListCommand() -> [String] {
        [scutilPath, "--nc", "list"]
    }

    // MARK: - Status & Output Parsing

    public static func parseScutilStatus(output: String) -> VPNStatus {
        let lower = output.lowercased()
        if lower.contains("disconnecting") {
            return .disconnecting
        } else if lower.contains("connecting") {
            return .connecting
        } else if lower.contains("connected") && !lower.contains("disconnected") {
            return .connected
        } else if lower.contains("no service") {
            return .error
        } else {
            return .disconnected
        }
    }

    public static func parseListOutput(output: String) -> [VPNServiceProfile] {
        var profiles: [VPNServiceProfile] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("Available") else { continue }
            let isDefault = line.contains("*")

            var status: VPNStatus = .disconnected
            if let openP = trimmed.firstIndex(of: "("),
               let closeP = trimmed[openP...].firstIndex(of: ")") {
                let statusStr = String(trimmed[trimmed.index(after: openP)..<closeP])
                status = parseScutilStatus(output: statusStr)
            }

            guard let q1 = trimmed.firstIndex(of: "\""),
                  let q2 = trimmed[trimmed.index(after: q1)...].firstIndex(of: "\"") else {
                continue
            }
            let name = String(trimmed[trimmed.index(after: q1)..<q2])

            var serviceID = UUID().uuidString
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            for token in tokens {
                if token.count == 36 && token.contains("-") {
                    serviceID = String(token)
                    break
                }
            }

            profiles.append(VPNServiceProfile(serviceID: serviceID, name: name, status: status, isDefault: isDefault))
        }

        return profiles
    }

    public static func parseProfileNames(output: String) -> [String] {
        let list = parseListOutput(output: output)
        if !list.isEmpty {
            return list.map(\.name)
        }
        var names: [String] = []
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if let q1 = line.firstIndex(of: "\""),
               let q2 = line[line.index(after: q1)...].firstIndex(of: "\"") {
                names.append(String(line[line.index(after: q1)..<q2]))
            }
        }
        return names
    }

    // MARK: - Profile Resolution

    public func resolveProfileName(_ requested: String) async -> String {
        if requested == "macos" {
            if let list = try? await listProfiles(), list.contains(where: { $0.name == "macos.ovpn" }) {
                return "macos.ovpn"
            }
            return "macos.ovpn"
        }
        return requested
    }

    // MARK: - Controller Actions

    public func checkStatus(profileName: String = defaultProfileName) async -> VPNStatus {
        let resolved = await resolveProfileName(profileName)
        guard let output = try? await runner.run(Self.scutilPath, arguments: ["--nc", "status", resolved], environment: nil, timeout: 5.0) else {
            return .error
        }
        let combined = (output.stdout + " " + output.stderr).lowercased()
        if !output.succeeded || combined.contains("no service") {
            return .error
        }
        return Self.parseScutilStatus(output: output.stdout)
    }

    public func connect(profileName: String = defaultProfileName) async throws {
        let current = await checkStatus(profileName: profileName)
        guard current != .connected && current != .connecting else { return } // Idempotent

        let resolved = await resolveProfileName(profileName)
        let output = try await runner.run(Self.scutilPath, arguments: ["--nc", "start", resolved], environment: nil, timeout: 10.0)
        guard output.succeeded else {
            throw VPNControllerError.commandFailed(exitCode: output.exitCode, message: output.stderr.isEmpty ? output.stdout : output.stderr)
        }
    }

    public func disconnect(profileName: String = defaultProfileName) async throws {
        let current = await checkStatus(profileName: profileName)
        guard current != .disconnected && current != .disconnecting else { return } // Idempotent

        let resolved = await resolveProfileName(profileName)
        let output = try await runner.run(Self.scutilPath, arguments: ["--nc", "stop", resolved], environment: nil, timeout: 10.0)
        guard output.succeeded else {
            throw VPNControllerError.commandFailed(exitCode: output.exitCode, message: output.stderr.isEmpty ? output.stdout : output.stderr)
        }
    }

    public func listProfiles() async throws -> [VPNServiceProfile] {
        let output = try await runner.run(Self.scutilPath, arguments: ["--nc", "list"], environment: nil, timeout: 5.0)
        guard output.succeeded else {
            throw VPNControllerError.commandFailed(exitCode: output.exitCode, message: output.stderr)
        }
        let list = Self.parseListOutput(output: output.stdout)
        lock.withLock { self.cachedProfiles = list }
        return list
    }

    // MARK: - VPNControllerProtocol Conformance

    public func parseProfile(url: URL) throws -> VPNProfileInfo {
        try OpenVPNParser.parse(fileURL: url)
    }

    public func detectConflicts(profile: VPNProfileInfo, currentLAN: String) -> [String] {
        RouteConflictDetector.detectConflicts(profile: profile, localSubnets: [currentLAN])
    }
}
