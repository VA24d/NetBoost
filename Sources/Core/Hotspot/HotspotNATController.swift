import Foundation

/// Protocol governing 802.1X Hotspot Sharing lifecycle and connected clients.
public protocol HotspotControllerProtocol: Sendable {
    func startHotspot(upstreamInterface: String, downstreamInterface: String) async throws
    func stopHotspot() async throws
    func connectedClients() async -> [HotspotClient]
}

/// Manages kernel IP forwarding, interface IP alias, and isolated Packet Filter NAT anchor rules.
public final class HotspotNATController: HotspotControllerProtocol, @unchecked Sendable {

    public private(set) var configuration: HotspotConfiguration
    public private(set) var isActive: Bool = false
    private let lock = NSLock()

    private let pfManager: PFNATAnchorManager
    private let sysctlController: SysctlForwardingController.Type
    private var ruleFilePath: String?

    public init(
        configuration: HotspotConfiguration = .default,
        pfManager: PFNATAnchorManager? = nil
    ) {
        self.configuration = configuration
        self.pfManager = pfManager ?? PFNATAnchorManager(
            anchorName: "netboost",
            upstreamInterface: configuration.upstreamInterface,
            clientSubnet: configuration.subnet
        )
        self.sysctlController = SysctlForwardingController.self
    }

    private func updateConfig(upstream: String, downstream: String) {
        lock.withLock {
            configuration.upstreamInterface = upstream
            configuration.interfaceName = downstream
        }
    }

    private func setActiveState(_ active: Bool) {
        lock.withLock {
            isActive = active
            configuration.isActive = active
        }
    }

    /// Starts hotspot sharing: enables IP forwarding, creates IP alias, and loads isolated PF NAT anchor.
    public func startHotspot(
        upstreamInterface: String,
        downstreamInterface: String
    ) async throws {
        updateConfig(upstream: upstreamInterface, downstream: downstreamInterface)

        // 1. Enable Kernel IP forwarding
        try await setIPForwarding(true)

        // 2. Configure Gateway IP alias on downstream interface (192.168.2.1/24)
        try await configureDownstreamAlias(interface: downstreamInterface, ip: configuration.gateway)

        // 3. Generate and load isolated PF NAT anchor rules
        let tempRuleFile = NSTemporaryDirectory() + "netboost_hotspot_\(UUID().uuidString).pf"
        let rules = pfManager.generateNATRule()
        try rules.write(toFile: tempRuleFile, atomically: true, encoding: .utf8)
        self.ruleFilePath = tempRuleFile

        // Dry-run validate PF rules
        let dryRunOutput = try await ShellCommand.run("/sbin/pfctl", arguments: ["-nf", tempRuleFile])
        guard dryRunOutput.succeeded else {
            throw PrivilegeError.executionFailed("PF NAT rule validation failed: \(dryRunOutput.stderr)")
        }

        // Load anchor and enable PF
        let loadCmd = pfManager.makeLoadAnchorCommand(ruleFile: tempRuleFile)
        let enableCmd = pfManager.makeEnablePFCommand()

        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(loadCmd[0], arguments: Array(loadCmd.dropFirst()))
            _ = try await ShellCommand.run(enableCmd[0], arguments: Array(enableCmd.dropFirst()))
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: "\(loadCmd.joined(separator: " ")) && \(enableCmd.joined(separator: " "))")
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "pf-load-anchor", arguments: [pfManager.anchorName, tempRuleFile])
                _ = try? await PrivilegeHelper.runHelper(action: "pf-enable")
            }
        }

        setActiveState(true)
    }

    /// Stops hotspot sharing: atomically flushes NetBoost PF anchor and restores sysctl IP forwarding.
    public func stopHotspot() async throws {
        // 1. Flush NetBoost PF anchor only
        let flushCmd = pfManager.makeFlushAnchorCommand()
        if PrivilegeHelper.isRoot {
            _ = try? await ShellCommand.run(flushCmd[0], arguments: Array(flushCmd.dropFirst()))
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: flushCmd[0], arguments: Array(flushCmd.dropFirst()))
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "pf-flush-anchor", arguments: [pfManager.anchorName])
            }
        }

        // 2. Clean up temporary rule file
        if let path = ruleFilePath {
            try? FileManager.default.removeItem(atPath: path)
            self.ruleFilePath = nil
        }

        // 3. Remove downstream IP alias
        let iface = configuration.interfaceName
        let ip = configuration.gateway
        _ = try? await ShellCommand.run("/sbin/ifconfig", arguments: [iface, "-alias", ip])

        // 4. Disable IP forwarding
        try? await setIPForwarding(false)

        setActiveState(false)
    }

    /// Lists active hotspot clients using ARPScanner.
    public func connectedClients() async -> [HotspotClient] {
        let scanner = ARPScanner()
        return (try? await scanner.scan(subnetPrefix: "192.168.2.")) ?? []
    }

    private func setIPForwarding(_ enable: Bool) async throws {
        let cmd = enable ? SysctlForwardingController.makeEnableCommand() : SysctlForwardingController.makeDisableCommand()
        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: cmd[0], arguments: Array(cmd.dropFirst()))
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "set-ip-forwarding", arguments: [enable ? "1" : "0"])
            }
        }
    }

    private func configureDownstreamAlias(interface: String, ip: String) async throws {
        let cmd = ["/sbin/ifconfig", interface, "alias", ip, "netmask", "255.255.255.0"]
        if PrivilegeHelper.isRoot {
            _ = try? await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        } else {
            _ = try? await PrivilegeHelper.runElevated(script: cmd.joined(separator: " "))
        }
    }
}

// MARK: - SysctlForwardingController

public struct SysctlForwardingController: Sendable {
    public static func makeQueryCommand() -> [String] {
        ["/usr/sbin/sysctl", "-n", "net.inet.ip.forwarding"]
    }

    public static func makeEnableCommand() -> [String] {
        ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1"]
    }

    public static func makeDisableCommand() -> [String] {
        ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0"]
    }

    public static func parseForwardingState(output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}

// MARK: - PFNATAnchorManager

public struct PFNATAnchorManager: Sendable {
    public let anchorName: String
    public let upstreamInterface: String
    public let clientSubnet: String

    public init(
        anchorName: String = "netboost",
        upstreamInterface: String = "en10",
        clientSubnet: String = "192.168.2.0/24"
    ) {
        self.anchorName = anchorName
        self.upstreamInterface = upstreamInterface
        self.clientSubnet = clientSubnet
    }

    public func generateNATRule() -> String {
        "nat on \(upstreamInterface) from \(clientSubnet) to any -> (\(upstreamInterface))\npass out quick on \(upstreamInterface) from \(clientSubnet) to any keep state\n"
    }

    public func makeLoadAnchorCommand(ruleFile: String) -> [String] {
        ["/sbin/pfctl", "-a", anchorName, "-f", ruleFile]
    }

    public func makeEnablePFCommand() -> [String] {
        ["/sbin/pfctl", "-e"]
    }

    public func makeFlushAnchorCommand() -> [String] {
        ["/sbin/pfctl", "-a", anchorName, "-F", "all"]
    }
}
