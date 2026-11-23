import Foundation

/// Protocol governing 802.1X Hotspot Sharing lifecycle and connected clients.
public protocol HotspotControllerProtocol: Sendable {
    func startHotspot(upstreamInterface: String, downstreamInterface: String) async throws
    func startHotspot(configuration: HotspotConfiguration) async throws
    func updateConfiguration(_ config: HotspotConfiguration)
    func isRadioBroadcasting() async -> Bool
    func stopHotspot() async throws
    func connectedClients() async -> [HotspotClient]
}

public extension HotspotControllerProtocol {
    func startHotspot(configuration: HotspotConfiguration) async throws {
        try await startHotspot(upstreamInterface: configuration.upstreamInterface, downstreamInterface: configuration.interfaceName)
    }

    func updateConfiguration(_ config: HotspotConfiguration) {}

    func isRadioBroadcasting() async -> Bool {
        DarwinSocketHelper.isInterfaceActive("bridge100") || DarwinSocketHelper.isInterfaceActive("ap1")
    }
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

    public func updateConfiguration(_ newConfig: HotspotConfiguration) {
        lock.withLock {
            self.configuration = newConfig
        }
    }

    public func isRadioBroadcasting() async -> Bool {
        DarwinSocketHelper.isInterfaceActive("bridge100") || DarwinSocketHelper.isInterfaceActive("ap1")
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

    /// Starts hotspot sharing using explicit configuration.
    public func startHotspot(configuration: HotspotConfiguration) async throws {
        updateConfiguration(configuration)
        try await startHotspot(
            upstreamInterface: configuration.upstreamInterface,
            downstreamInterface: configuration.interfaceName
        )
    }

    /// Starts hotspot sharing: enables IP forwarding, creates IP alias, and loads isolated PF NAT anchor in a single elevated command.
    public func startHotspot(
        upstreamInterface: String,
        downstreamInterface: String
    ) async throws {
        updateConfig(upstream: upstreamInterface, downstream: downstreamInterface)

        // Clean up any previously orphaned rule file
        if let existingPath = self.ruleFilePath {
            try? FileManager.default.removeItem(atPath: existingPath)
            self.ruleFilePath = nil
        }

        // Generate and write isolated PF NAT anchor rules
        let tempRuleFile = NSTemporaryDirectory() + "netboost_hotspot_\(UUID().uuidString).pf"
        let rules = pfManager.generateNATRule()
        try rules.write(toFile: tempRuleFile, atomically: true, encoding: .utf8)
        self.ruleFilePath = tempRuleFile

        // Dry-run validate PF rules
        let dryRunOutput = try await ShellCommand.run("/sbin/pfctl", arguments: ["-nf", tempRuleFile])
        guard dryRunOutput.succeeded else {
            try? FileManager.default.removeItem(atPath: tempRuleFile)
            self.ruleFilePath = nil
            throw PrivilegeError.executionFailed("PF NAT rule validation failed: \(dryRunOutput.stderr)")
        }

        let sysctlCmd = "/usr/sbin/sysctl -w net.inet.ip.forwarding=1"
        let aliasCmd = "/sbin/ifconfig \(downstreamInterface) alias \(configuration.gateway) netmask 255.255.255.0"
        let loadAnchorCmd = "/sbin/pfctl -a \(pfManager.anchorName) -f \(tempRuleFile)"
        let enablePFCmd = "/sbin/pfctl -e 2>/dev/null || true"
        let powerOnCmd = "/usr/sbin/networksetup -setairportpower \(downstreamInterface) on 2>/dev/null || true"
        let natPlistCmd = "/usr/bin/defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict AirPort \"{ Channel = 0; Enabled = 1; NetworkName = \\\"\(configuration.ssid)\\\"; NetworkPassword = \\\"\(configuration.password)\\\"; }\" Enabled -int 1 PrimaryInterface \"\(upstreamInterface)\" SharingInterfaces \"(\\\"AirPort\\\", \\\"\(downstreamInterface)\\\")\" 2>/dev/null || true"
        let kickstartSharingCmd = "(/bin/launchctl kickstart -k system/com.apple.NetworkSharing 2>/dev/null || /bin/launchctl start com.apple.NetworkSharing 2>/dev/null || true)"

        let combinedStart = "\(sysctlCmd) && \(aliasCmd) && \(loadAnchorCmd) && (\(enablePFCmd)) && (\(powerOnCmd)) && (\(natPlistCmd)) && (\(kickstartSharingCmd))"

        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.runBash(combinedStart)
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: combinedStart)
            } catch PrivilegeError.elevationDenied {
                try? FileManager.default.removeItem(atPath: tempRuleFile)
                self.ruleFilePath = nil
                throw PrivilegeError.elevationDenied
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "pf-load-anchor", arguments: [pfManager.anchorName, tempRuleFile])
                _ = try? await PrivilegeHelper.runHelper(action: "pf-enable")
                _ = try? await PrivilegeHelper.runHelper(action: "set-ip-forwarding", arguments: ["1"])
            }
        }

        setActiveState(true)
    }

    /// Stops hotspot sharing: atomically flushes NetBoost PF anchor, removes alias, and restores sysctl IP forwarding.
    public func stopHotspot() async throws {
        let flushCmd = "/sbin/pfctl -a \(pfManager.anchorName) -F all 2>/dev/null || true"
        let unaliasCmd = "/sbin/ifconfig \(configuration.interfaceName) -alias \(configuration.gateway) 2>/dev/null || true"
        let sysctlCmd = "/usr/sbin/sysctl -w net.inet.ip.forwarding=0 2>/dev/null || true"
        let stopSharingCmd = "/bin/launchctl stop com.apple.NetworkSharing 2>/dev/null || true"
        let disableNatPlistCmd = "/usr/bin/defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict-add Enabled 0 2>/dev/null || true"

        let combinedStop = "\(flushCmd) ; \(unaliasCmd) ; \(sysctlCmd) ; (\(stopSharingCmd)) ; (\(disableNatPlistCmd))"

        if PrivilegeHelper.isRoot {
            _ = try? await ShellCommand.runBash(combinedStop)
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: combinedStop)
            } catch PrivilegeError.elevationDenied {
                throw PrivilegeError.elevationDenied
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "pf-flush-anchor", arguments: [pfManager.anchorName])
                _ = try? await PrivilegeHelper.runHelper(action: "set-ip-forwarding", arguments: ["0"])
            }
        }

        if let path = ruleFilePath {
            try? FileManager.default.removeItem(atPath: path)
            self.ruleFilePath = nil
        }

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
            } catch PrivilegeError.elevationDenied {
                throw PrivilegeError.elevationDenied
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
