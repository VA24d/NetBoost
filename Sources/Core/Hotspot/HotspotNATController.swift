import Foundation
import Darwin
import SystemConfiguration

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

    private var _configuration: HotspotConfiguration
    private var _isActive: Bool = false
    private let lock = NSLock()

    public var configuration: HotspotConfiguration {
        lock.withLock { _configuration }
    }

    public var isActive: Bool {
        lock.withLock { _isActive }
    }

    private let anchorName: String
    private let sysctlController: SysctlForwardingController.Type
    private let dhcpServer: DHCPServer

    /// Computed PF NAT anchor manager always reflecting the latest configuration while preserving the configured anchor name.
    public var pfManager: PFNATAnchorManager {
        effectivePFManager()
    }

    public init(
        configuration: HotspotConfiguration = .default,
        pfManager: PFNATAnchorManager? = nil,
        dhcpServer: DHCPServer? = nil
    ) {
        self._configuration = configuration
        self.anchorName = pfManager?.anchorName ?? "netboost"
        self.sysctlController = SysctlForwardingController.self
        self.dhcpServer = dhcpServer ?? DHCPServer(config: configuration)
    }

    /// Returns a PFNATAnchorManager synchronized with the controller's current upstream interface and subnet.
    public func effectivePFManager() -> PFNATAnchorManager {
        lock.withLock {
            PFNATAnchorManager(
                anchorName: anchorName,
                upstreamInterface: _configuration.upstreamInterface,
                clientSubnet: _configuration.subnet
            )
        }
    }

    public func updateConfiguration(_ newConfig: HotspotConfiguration) {
        lock.withLock {
            self._configuration = newConfig
        }
    }

    public func isRadioBroadcasting() async -> Bool {
        DarwinSocketHelper.isInterfaceActive("bridge100") || DarwinSocketHelper.isInterfaceActive("ap1")
    }

    // MARK: - Input Validation & NAT Plist Generation

    /// Validates that a BSD interface name contains only ASCII alphanumeric characters (`^[a-zA-Z0-9]+$`).
    public static func isValidBSDInterfaceName(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: "^[a-zA-Z0-9]+$", options: .regularExpression) != nil
    }

    /// Validates that an interface is a physical/service BSD name eligible for hotspot upstream or downstream use.
    public static func isEligibleHotspotInterface(_ name: String) -> Bool {
        guard isValidBSDInterfaceName(name) else { return false }
        let lower = name.lowercased()
        let disallowedPrefixes = ["lo", "bridge", "utun", "awdl", "llw", "gif", "stf", "anpi", "ap"]
        return !disallowedPrefixes.contains(where: { lower.hasPrefix($0) })
    }

    /// Validates a dotted-quad IPv4 address string.
    public static func isValidIPv4Address(_ address: String) -> Bool {
        guard !address.isEmpty, address.range(of: "^[0-9.]+$", options: .regularExpression) != nil else {
            return false
        }
        var addr = in_addr()
        return inet_pton(AF_INET, address, &addr) == 1
    }

    /// Validates an IPv4 CIDR subnet string (e.g. `192.168.2.0/24`).
    public static func isValidIPv4CIDR(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              isValidIPv4Address(String(parts[0])),
              let prefix = Int(parts[1]),
              (0...32).contains(prefix) else {
            return false
        }
        return true
    }

    /// Validates an IPv4 CIDR suitable for hotspot NAT/DHCP sharing (`8...30` prefix).
    public static func isValidHotspotSubnetCIDR(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              isValidIPv4Address(String(parts[0])),
              let prefix = Int(parts[1]),
              (8...30).contains(prefix) else {
            return false
        }
        return true
    }

    /// Checks whether `address` falls inside the given IPv4 CIDR subnet.
    public static func isIPv4(_ address: String, inCIDR cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (8...30).contains(prefix),
              let ipVal = RouteConflictDetector.ipv4ToUInt32(address),
              let netVal = RouteConflictDetector.ipv4ToUInt32(String(parts[0])) else {
            return false
        }
        let mask: UInt32 = ~UInt32(0) << (32 - prefix)
        return (ipVal & mask) == (netVal & mask)
    }

    /// Validates hotspot networking parameters, throwing `PrivilegeError.executionFailed` on invalid input.
    public static func validateConfiguration(
        upstreamInterface: String,
        downstreamInterface: String,
        gateway: String,
        subnet: String
    ) throws {
        guard isEligibleHotspotInterface(upstreamInterface) else {
            throw PrivilegeError.executionFailed("Invalid upstream BSD interface name: '\(upstreamInterface)'")
        }
        guard isEligibleHotspotInterface(downstreamInterface) else {
            throw PrivilegeError.executionFailed("Invalid downstream BSD interface name: '\(downstreamInterface)'")
        }
        guard upstreamInterface != downstreamInterface else {
            throw PrivilegeError.executionFailed("Upstream and downstream interfaces must be distinct ('\(upstreamInterface)')")
        }
        guard isValidIPv4Address(gateway) else {
            throw PrivilegeError.executionFailed("Invalid hotspot gateway IPv4 address: '\(gateway)'")
        }
        guard isValidHotspotSubnetCIDR(subnet) else {
            throw PrivilegeError.executionFailed("Invalid hotspot subnet CIDR (expected /8 to /30): '\(subnet)'")
        }
        guard isIPv4(gateway, inCIDR: subnet) else {
            throw PrivilegeError.executionFailed("Hotspot gateway '\(gateway)' is outside subnet '\(subnet)'")
        }
    }

    /// Resolves the macOS SCNetworkService UUID for a BSD interface name (e.g. `en10`).
    public static func resolvePrimaryServiceID(for bsdInterface: String) -> String? {
        guard isValidBSDInterfaceName(bsdInterface),
              let prefs = SCPreferencesCreate(nil, "com.netboost.prefs" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {
            return nil
        }
        for service in services where SCNetworkServiceGetEnabled(service) {
            if let iface = SCNetworkServiceGetInterface(service),
               let dev = SCNetworkInterfaceGetBSDName(iface) as String?,
               dev == bsdInterface,
               let sid = SCNetworkServiceGetServiceID(service) as String? {
                return sid
            }
        }
        return nil
    }

    private static func sharingNetworkBounds(from cidr: String) -> (start: String, end: String, mask: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (8...30).contains(prefix),
              let ipInt = RouteConflictDetector.ipv4ToUInt32(String(parts[0])) else {
            return ("192.168.2.0", "192.168.2.254", "255.255.255.0")
        }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        let network = ipInt & mask
        let broadcast = network | ~mask
        let lastHost = broadcast > network ? broadcast - 1 : network
        return (
            RouteConflictDetector.uInt32ToIPv4(network),
            RouteConflictDetector.uInt32ToIPv4(lastHost),
            RouteConflictDetector.uInt32ToIPv4(mask)
        )
    }

    /// Builds the `NAT` configuration dictionary expected by `com.apple.nat.plist` and `InternetSharingPreference`.
    public static func makeNATDictionary(
        configuration: HotspotConfiguration,
        upstreamInterface: String,
        downstreamInterface: String,
        primaryServiceID: String? = nil
    ) -> [String: Any] {
        let bounds = sharingNetworkBounds(from: configuration.subnet)
        let airportDict: [String: Any] = [
            "Channel": 0,
            "Enabled": 1,
            "NetworkName": configuration.ssid,
            "NetworkPassword": configuration.password,
            "SecurityType": configuration.securityType.rawValue
        ]
        var natDict: [String: Any] = [
            "AirPort": airportDict,
            "EnableDHCP": 1,
            "EnableDNS": 1,
            "EnableNATPMP": 1,
            "Enabled": 1,
            "NatType": "nat",
            "PrimaryInterface": upstreamInterface,
            "SharingDevices": [downstreamInterface],
            "SharingInterfaces": ["AirPort", downstreamInterface],
            "SharingNetworkMask": bounds.mask,
            "SharingNetworkNumberEnd": bounds.end,
            "SharingNetworkNumberStart": bounds.start
        ]
        if let serviceID = primaryServiceID ?? resolvePrimaryServiceID(for: upstreamInterface) {
            natDict["PrimaryService"] = serviceID
        }
        return natDict
    }

    /// Serializes macOS `com.apple.nat` XML property list data safely without shell interpolation.
    public static func makeNATPropertyListData(
        configuration: HotspotConfiguration,
        upstreamInterface: String,
        downstreamInterface: String
    ) throws -> Data {
        let natDict = makeNATDictionary(
            configuration: configuration,
            upstreamInterface: upstreamInterface,
            downstreamInterface: downstreamInterface
        )
        let rootPlist: [String: Any] = ["NAT": natDict]
        return try PropertyListSerialization.data(fromPropertyList: rootPlist, format: .xml, options: 0)
    }

    private func updateConfig(upstream: String, downstream: String) {
        lock.withLock {
            _configuration.upstreamInterface = upstream
            _configuration.interfaceName = downstream
        }
    }

    private func setActiveState(_ active: Bool) {
        lock.withLock {
            _isActive = active
            _configuration.isActive = active
        }
    }

    private func currentConfigurationSnapshot() -> HotspotConfiguration {
        lock.withLock { _configuration }
    }

    /// Builds the atomic elevated shell script for starting hotspot sharing.
    public func buildStartCommand(
        ruleFile: String,
        natPlistFile: String,
        upstreamInterface: String,
        downstreamInterface: String,
        bridge100Active: Bool = DarwinSocketHelper.isInterfaceActive("bridge100")
    ) throws -> String {
        let config = currentConfigurationSnapshot()
        try Self.validateConfiguration(
            upstreamInterface: upstreamInterface,
            downstreamInterface: downstreamInterface,
            gateway: config.gateway,
            subnet: config.subnet
        )

        let effectivePF = effectivePFManager()
        guard HelperConstants.isValidAnchorName(effectivePF.anchorName) else {
            throw PrivilegeError.executionFailed("Invalid PF anchor name: '\(effectivePF.anchorName)'")
        }
        let bounds = Self.sharingNetworkBounds(from: config.subnet)
        let quotedRuleFile = ShellCommand.shellQuote(ruleFile)
        let quotedNATPlist = ShellCommand.shellQuote(natPlistFile)
        let quotedAnchor = ShellCommand.shellQuote(effectivePF.anchorName)
        let appleAnchor = effectivePF.appleAnchorName
        let quotedAppleAnchor = ShellCommand.shellQuote(appleAnchor)
        let quotedDownstream = ShellCommand.shellQuote(downstreamInterface)
        let quotedGateway = ShellCommand.shellQuote(config.gateway)
        let quotedNetmask = ShellCommand.shellQuote(bounds.mask)

        var requiredCommands: [String] = [
            "/usr/sbin/sysctl -w net.inet.ip.forwarding=1"
        ]
        if !bridge100Active {
            requiredCommands.append("/sbin/ifconfig \(quotedDownstream) alias \(quotedGateway) netmask \(quotedNetmask)")
        }
        requiredCommands.append("/sbin/pfctl -a \(quotedAnchor) -f \(quotedRuleFile)")
        if appleAnchor != effectivePF.anchorName {
            requiredCommands.append("/sbin/pfctl -a \(quotedAppleAnchor) -f \(quotedRuleFile)")
        }

        let optionalSharingTriggers: [String] = [
            "(/sbin/pfctl -e 2>/dev/null || true)",
            "(/usr/sbin/networksetup -setairportpower \(quotedDownstream) on 2>/dev/null || true)",
            "(/usr/bin/defaults import /Library/Preferences/SystemConfiguration/com.apple.nat \(quotedNATPlist) 2>/dev/null || true)",
            "(/bin/launchctl kickstart -k system/com.apple.NetworkSharing 2>/dev/null || /bin/launchctl start com.apple.NetworkSharing 2>/dev/null || true)"
        ]

        return (requiredCommands + optionalSharingTriggers).joined(separator: " && ")
    }

    /// Builds the atomic elevated shell script for stopping hotspot sharing.
    public func buildStopCommand() throws -> String {
        let config = currentConfigurationSnapshot()
        guard Self.isEligibleHotspotInterface(config.interfaceName) else {
            throw PrivilegeError.executionFailed("Invalid downstream BSD interface name: '\(config.interfaceName)'")
        }
        guard Self.isValidIPv4Address(config.gateway) else {
            throw PrivilegeError.executionFailed("Invalid hotspot gateway IPv4 address: '\(config.gateway)'")
        }

        let effectivePF = effectivePFManager()
        guard HelperConstants.isValidAnchorName(effectivePF.anchorName) else {
            throw PrivilegeError.executionFailed("Invalid PF anchor name: '\(effectivePF.anchorName)'")
        }
        let quotedAnchor = ShellCommand.shellQuote(effectivePF.anchorName)
        let appleAnchor = effectivePF.appleAnchorName
        let quotedAppleAnchor = ShellCommand.shellQuote(appleAnchor)
        let quotedDownstream = ShellCommand.shellQuote(config.interfaceName)
        let quotedGateway = ShellCommand.shellQuote(config.gateway)

        var commands: [String] = [
            "/sbin/pfctl -a \(quotedAnchor) -F all 2>/dev/null || true"
        ]
        if appleAnchor != effectivePF.anchorName {
            commands.append("/sbin/pfctl -a \(quotedAppleAnchor) -F all 2>/dev/null || true")
        }
        commands.append("/sbin/ifconfig \(quotedDownstream) -alias \(quotedGateway) 2>/dev/null || true")
        commands.append("/usr/sbin/sysctl -w net.inet.ip.forwarding=0 2>/dev/null || true")
        commands.append("(/bin/launchctl stop com.apple.NetworkSharing 2>/dev/null || true)")
        commands.append("(/usr/bin/defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict-add Enabled -int 0 2>/dev/null || true)")

        return commands.joined(separator: " ; ")
    }

    private func validateFullHotspotConfiguration(_ config: HotspotConfiguration) throws {
        try Self.validateConfiguration(
            upstreamInterface: config.upstreamInterface,
            downstreamInterface: config.interfaceName,
            gateway: config.gateway,
            subnet: config.subnet
        )
        guard Self.isValidIPv4Address(config.dhcpRangeStart),
              Self.isValidIPv4Address(config.dhcpRangeEnd),
              Self.isIPv4(config.dhcpRangeStart, inCIDR: config.subnet),
              Self.isIPv4(config.dhcpRangeEnd, inCIDR: config.subnet),
              let startInt = RouteConflictDetector.ipv4ToUInt32(config.dhcpRangeStart),
              let endInt = RouteConflictDetector.ipv4ToUInt32(config.dhcpRangeEnd),
              startInt <= endInt else {
            throw PrivilegeError.executionFailed("Invalid hotspot DHCP pool range for subnet '\(config.subnet)'")
        }
        guard !config.ssid.isEmpty, config.ssid.utf8.count <= 32, !config.ssid.contains("\0") else {
            throw PrivilegeError.executionFailed("Hotspot SSID must be 1 to 32 UTF-8 bytes")
        }
        guard (8...63).contains(config.password.utf8.count), !config.password.contains("\0") else {
            throw PrivilegeError.executionFailed("Hotspot WPA passphrase must be 8 to 63 UTF-8 bytes")
        }
    }

    /// Starts hotspot sharing using explicit configuration.
    public func startHotspot(configuration: HotspotConfiguration) async throws {
        try validateFullHotspotConfiguration(configuration)
        updateConfiguration(configuration)
        try await startHotspot(
            upstreamInterface: configuration.upstreamInterface,
            downstreamInterface: configuration.interfaceName
        )
    }

    /// Starts hotspot sharing: validates inputs, enables IP forwarding, configures interface alias, and loads isolated PF NAT anchors.
    public func startHotspot(
        upstreamInterface: String,
        downstreamInterface: String
    ) async throws {
        var candidate = currentConfigurationSnapshot()
        candidate.upstreamInterface = upstreamInterface
        candidate.interfaceName = downstreamInterface
        try validateFullHotspotConfiguration(candidate)

        let effectivePF = lock.withLock {
            PFNATAnchorManager(
                anchorName: anchorName,
                upstreamInterface: candidate.upstreamInterface,
                clientSubnet: candidate.subnet
            )
        }
        guard HelperConstants.isValidAnchorName(effectivePF.anchorName) else {
            throw PrivilegeError.executionFailed("Invalid PF anchor name: '\(effectivePF.anchorName)'")
        }

        updateConfig(upstream: upstreamInterface, downstream: downstreamInterface)

        if !PrivilegeHelper.isRoot && (PrivilegeHelper.locateBundledOrBuiltHelperExecutable() != nil || PrivilegeHelper.isHelperDaemonInstalled) {
            do {
                _ = try await PrivilegeHelper.runDaemonAction(
                    action: .hotspotStart,
                    arguments: [
                        upstreamInterface,
                        downstreamInterface,
                        candidate.gateway,
                        candidate.subnet,
                        candidate.dhcpRangeStart,
                        candidate.dhcpRangeEnd,
                        candidate.ssid,
                        candidate.securityType.rawValue,
                        candidate.password
                    ]
                )
                setActiveState(true)
                return
            } catch PrivilegeError.helperNotFound {
                // Fall back to local elevated shell workflow when daemon is unavailable.
            }
        }

        try await startHotspotViaShellFallback(
            snapshot: candidate,
            effectivePF: effectivePF,
            upstreamInterface: upstreamInterface,
            downstreamInterface: downstreamInterface
        )
        setActiveState(true)
    }

    private func startHotspotViaShellFallback(
        snapshot: HotspotConfiguration,
        effectivePF: PFNATAnchorManager,
        upstreamInterface: String,
        downstreamInterface: String
    ) async throws {
        let tempRuleFile = (NSTemporaryDirectory() as NSString).appendingPathComponent("netboost_hotspot_\(UUID().uuidString).pf")
        defer { try? FileManager.default.removeItem(atPath: tempRuleFile) }

        let rules = effectivePF.generateNATRule()
        do {
            try rules.write(toFile: tempRuleFile, atomically: true, encoding: .utf8)
        } catch {
            throw PrivilegeError.executionFailed("Failed to write PF NAT rule file: \(error.localizedDescription)")
        }

        let dryRunOutput = try await ShellCommand.run("/sbin/pfctl", arguments: ["-nf", tempRuleFile])
        guard dryRunOutput.succeeded else {
            throw PrivilegeError.executionFailed("PF NAT rule validation failed: \(dryRunOutput.stderr)")
        }

        let tempNATPlist = (NSTemporaryDirectory() as NSString).appendingPathComponent("netboost_nat_\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(atPath: tempNATPlist) }

        let plistData = try Self.makeNATPropertyListData(
            configuration: snapshot,
            upstreamInterface: upstreamInterface,
            downstreamInterface: downstreamInterface
        )
        try plistData.write(to: URL(fileURLWithPath: tempNATPlist), options: .atomic)

        let lintOutput = try await ShellCommand.run("/usr/bin/plutil", arguments: ["-lint", tempNATPlist])
        guard lintOutput.succeeded else {
            throw PrivilegeError.executionFailed("NAT plist lint failed: \(lintOutput.stderr)")
        }

        let combinedStart = try buildStartCommand(
            ruleFile: tempRuleFile,
            natPlistFile: tempNATPlist,
            upstreamInterface: upstreamInterface,
            downstreamInterface: downstreamInterface
        )

        if PrivilegeHelper.isRoot {
            let output = try await ShellCommand.runBash(combinedStart)
            guard output.succeeded else {
                let msg = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PrivilegeError.executionFailed(msg.isEmpty ? "Hotspot start failed with exit code \(output.exitCode)" : msg)
            }
        } else {
            _ = try await PrivilegeHelper.runElevated(script: combinedStart)
        }
    }

    /// Stops hotspot sharing: atomically flushes NetBoost PF anchors, removes alias, and restores sysctl IP forwarding.
    public func stopHotspot() async throws {
        let snapshot = currentConfigurationSnapshot()
        let combinedStop = try buildStopCommand()

        do {
            let output = try await PrivilegeHelper.executeDaemonOrElevated(
                daemonAction: .hotspotStop,
                daemonArguments: [snapshot.interfaceName, snapshot.gateway],
                fallbackScript: combinedStop
            )
            if PrivilegeHelper.isRoot && !output.succeeded {
                let msg = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PrivilegeError.executionFailed(msg.isEmpty ? "Hotspot stop failed with exit code \(output.exitCode)" : msg)
            }
        } catch let err as PrivilegeError {
            throw err
        } catch {
            throw PrivilegeError.executionFailed(error.localizedDescription)
        }

        setActiveState(false)
    }

    /// Lists active hotspot clients using ARPScanner across 192.168.2.0/24 and 192.168.3.0/24 enriched with DHCP & bootpd leases.
    public func connectedClients() async -> [HotspotClient] {
        let scanner = ARPScanner()
        let bootpdLeases = DHCPServer.parseBootpdLeases()
        let mergedLeases = dhcpServer.allLeases + bootpdLeases

        var prefixes = ["192.168.2.", "192.168.3."]
        let gateway = currentConfigurationSnapshot().gateway
        let components = gateway.split(separator: ".")
        if components.count == 4 {
            let customPrefix = "\(components[0]).\(components[1]).\(components[2])."
            if !prefixes.contains(customPrefix) {
                prefixes.append(customPrefix)
            }
        }

        return (try? await scanner.scan(subnetPrefixes: prefixes, leases: mergedLeases)) ?? []
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

    /// The macOS `/etc/pf.conf`-evaluated anchor path (`com.apple/<anchorName>`).
    public var appleAnchorName: String {
        anchorName.hasPrefix("com.apple/") ? anchorName : "com.apple/\(anchorName)"
    }

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
        generateNATRules()
    }

    /// Generates PF rules with strict section ordering: normalization (`scrub`), translation (`nat`), then filtering (`pass`).
    public func generateNATRules(additionalSubnets: [String] = []) -> String {
        let allSubnets = [clientSubnet] + additionalSubnets.filter { $0 != clientSubnet }
        var lines: [String] = [
            "scrub on bridge100 all max-mss 1440 no-df"
        ]
        for sub in allSubnets {
            lines.append("nat on \(upstreamInterface) from \(sub) to any -> (\(upstreamInterface))")
        }
        lines.append("pass quick on bridge100 inet all keep state")
        for sub in allSubnets {
            lines.append("pass out quick on \(upstreamInterface) from \(sub) to any keep state")
        }
        lines.append("pass out quick on \(upstreamInterface) inet from (\(upstreamInterface)) to any keep state")
        return lines.joined(separator: "\n")
    }

    public func makeLoadAnchorCommand(ruleFile: String) -> [String] {
        ["/sbin/pfctl", "-a", anchorName, "-f", ruleFile]
    }

    public func makeLoadAppleAnchorCommand(ruleFile: String) -> [String] {
        ["/sbin/pfctl", "-a", appleAnchorName, "-f", ruleFile]
    }

    public func makeEnablePFCommand() -> [String] {
        ["/sbin/pfctl", "-e"]
    }

    public func makeFlushAnchorCommand() -> [String] {
        ["/sbin/pfctl", "-a", anchorName, "-F", "all"]
    }

    public func makeFlushAppleAnchorCommand() -> [String] {
        ["/sbin/pfctl", "-a", appleAnchorName, "-F", "all"]
    }
}
