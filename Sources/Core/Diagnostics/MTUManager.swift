import Foundation

/// Errors encountered when inspecting or setting interface MTU boundaries.
public enum MTUBoundaryError: Error, LocalizedError, Equatable, Sendable {
    case belowMinimum(Int)
    case exceedsMaximum(Int)

    public var errorDescription: String? {
        switch self {
        case .belowMinimum(let mtu):
            return "MTU \(mtu) is below IPv4 minimum specification of 576 bytes."
        case .exceedsMaximum(let mtu):
            return "MTU \(mtu) exceeds standard ethernet maximum threshold of 1500 bytes."
        }
    }
}

/// Inspects and manages network interface MTU, automatically tuning for cellular vs campus LAN.
public final class MTUManager: Sendable {

    public static let cellularOptimalMTU = 1280
    public static let ethernetOptimalMTU = 1500
    public static let minimumMTU = 576
    public static let maximumMTU = 1500

    public init() {}

    /// Validates MTU parameters and returns command string, quoting service names with spaces.
    public static func validateAndGenerateMTUCommand(service: String, mtu: Int) throws -> String {
        guard mtu >= minimumMTU else {
            throw MTUBoundaryError.belowMinimum(mtu)
        }
        guard mtu <= maximumMTU else {
            throw MTUBoundaryError.exceedsMaximum(mtu)
        }
        let quotedService = service.contains(" ") ? "\"\(service)\"" : service
        return "networksetup -setMTU \(quotedService) \(mtu)"
    }

    /// Recommends optimal MTU and determines if fix is needed.
    public func recommendMTU(isCellular: Bool, currentMTU: Int) -> (optimalMTU: Int, fixNeeded: Bool) {
        MTUInspector.recommendMTU(isCellular: isCellular, currentMTU: currentMTU)
    }

    /// Queries the current MTU for a network service via networksetup.
    public func getMTU(service: String) async throws -> Int? {
        let cmd = MTUInspector.makeGetMTUCommand(service: service)
        let output = try await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        guard output.succeeded else { return nil }
        return MTUInspector.parseGetMTUOutput(output.stdout)
    }

    /// Sets the MTU for a network service using privileged helper or direct execution.
    public func setMTU(service: String, mtu: Int) async throws {
        _ = try Self.validateAndGenerateMTUCommand(service: service, mtu: mtu)

        let cmd = MTUInspector.makeSetMTUCommand(service: service, mtu: mtu)
        let fallbackScript = cmd.map(ShellCommand.shellQuote).joined(separator: " ")
        let output = try await PrivilegeHelper.executeDaemonOrElevated(
            rootExecutable: cmd[0],
            rootArguments: Array(cmd.dropFirst()),
            daemonAction: .setMTU,
            daemonArguments: [service, String(mtu)],
            fallbackScript: fallbackScript
        )
        if PrivilegeHelper.isRoot && !output.succeeded {
            throw ShellError.executionFailed(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
        }
    }

    /// Diagnoses whether an interface on a cellular connection has a suboptimal MTU.
    public func detectSuboptimalMTU(interface: NetworkInterfaceInfo, isCellular: Bool) -> DetectedIssue? {
        if isCellular && interface.mtu > Self.cellularOptimalMTU {
            return DetectedIssue(
                severity: .warning,
                title: "MTU \(interface.mtu) on Cellular Hotspot",
                description: "High packet drop and TLS bad record MAC risks over cellular.",
                recommendedFixAction: "networksetup -setMTU \(interface.displayName.contains(" ") ? "\"\(interface.displayName)\"" : interface.displayName) \(Self.cellularOptimalMTU)",
                automatedFixAvailable: true
            )
        }
        return nil
    }
}

// MARK: - MTUInspector Interface

public struct MTUInspector: Sendable {

    public static func recommendMTU(isCellular: Bool, currentMTU: Int) -> (optimalMTU: Int, fixNeeded: Bool) {
        let optimal = isCellular ? MTUManager.cellularOptimalMTU : MTUManager.ethernetOptimalMTU
        return (optimal, currentMTU != optimal)
    }

    public static func makeSetMTUCommand(service: String, mtu: Int) -> [String] {
        ["/usr/sbin/networksetup", "-setMTU", service, String(mtu)]
    }

    public static func makeGetMTUCommand(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-getMTU", service]
    }

    public static func parseGetMTUOutput(_ output: String) -> Int? {
        // "Active MTU: 1280 (Current Setting: 1280)" or "MTU: 1500"
        for token in output.split(separator: " ") {
            let clean = token.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
            if let val = Int(clean), val >= 576 && val <= 9000 {
                return val
            }
        }
        return nil
    }
}
