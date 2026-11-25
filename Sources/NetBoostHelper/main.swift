import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN
import NetBoostCore

private let systemMutationLock = NSLock()

private func writeStderr(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func runBinary(_ executablePath: String, arguments: [String] = [], timeout: TimeInterval = 30.0) -> HelperResponse {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let exitSem = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        exitSem.signal()
    }

    do {
        try process.run()
    } catch {
        return HelperResponse(exitCode: 1, stdout: "", stderr: "Failed to launch \(executablePath): \(error.localizedDescription)")
    }

    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func set(_ data: Data) {
            lock.withLock { storage = data }
        }

        func get() -> Data {
            lock.withLock { storage }
        }
    }
    let outBox = DataBox()
    let errBox = DataBox()
    let readGroup = DispatchGroup()

    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        outBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        readGroup.leave()
    }

    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        errBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        readGroup.leave()
    }

    let waitResult = exitSem.wait(timeout: .now() + timeout)
    if waitResult == .timedOut {
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            _ = exitSem.wait(timeout: .now() + 0.25)
            if process.isRunning && pid > 0 {
                _ = Darwin.kill(pid, SIGKILL)
                _ = exitSem.wait(timeout: .now() + 0.5)
            }
        }
        _ = readGroup.wait(timeout: .now() + 0.5)
        return HelperResponse(exitCode: 124, stdout: "", stderr: "Helper command \(executablePath) timed out after \(Int(timeout))s")
    }

    _ = readGroup.wait(timeout: .now() + 2.0)

    let stdout = String(data: outBox.get(), encoding: .utf8) ?? ""
    let stderr = String(data: errBox.get(), encoding: .utf8) ?? ""
    return HelperResponse(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}

private func resolveServiceName(_ target: String) -> String {
    guard target.range(of: "^en[0-9]+$", options: .regularExpression) != nil else {
        return target
    }
    let orderOutput = runBinary("/usr/sbin/networksetup", arguments: ["-listnetworkserviceorder"])
    guard orderOutput.succeeded else {
        return target
    }
    let entries = ServiceOrderManager.parseServiceOrder(output: orderOutput.stdout)
    if let active = entries.first(where: { $0.device == target && !$0.name.hasPrefix("*") }) {
        return active.name
    }
    if let anyMatch = entries.first(where: { $0.device == target }) {
        return anyMatch.name.hasPrefix("*")
            ? String(anyMatch.name.dropFirst()).trimmingCharacters(in: .whitespaces)
            : anyMatch.name
    }
    return target
}

private func routeArguments(
    action: String,
    subnet: String,
    gateway: String,
    interface: String?
) -> [String] {
    var args = ["-n", action, "-net"]
    if subnet.contains("/") {
        let parts = subnet.split(separator: "/")
        let network = String(parts[0])
        let prefix = Int(parts[1]) ?? 32
        let netmask = RoutePinningEngine.cidrToNetmask(prefix: prefix)
        args.append(contentsOf: [network, "-netmask", netmask, gateway])
    } else {
        args.append(contentsOf: [subnet, gateway])
    }
    if let iface = interface {
        args.append(contentsOf: ["-ifp", iface])
    }
    return args
}

private func ensureRootOwnedDirectory(_ path: String, mode: mode_t) -> Bool {
    if Darwin.mkdir(path, mode) != 0 && errno != EEXIST {
        return false
    }
    let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else {
        return false
    }
    defer { Darwin.close(fd) }

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0,
          (st.st_mode & S_IFMT) == S_IFDIR else {
        return false
    }
    guard Darwin.fchown(fd, 0, 0) == 0, Darwin.fchmod(fd, mode) == 0 else {
        return false
    }
    return true
}

private func readAuthorizedUID() -> uid_t {
    let fd = Darwin.open(HelperConstants.authorizedUIDPath, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else {
        return 0
    }
    defer { Darwin.close(fd) }

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0,
          (st.st_mode & S_IFMT) == S_IFREG,
          st.st_uid == 0,
          (st.st_mode & 0o022) == 0 else {
        return 0
    }

    var buffer = [UInt8](repeating: 0, count: 64)
    let bytesRead = Darwin.read(fd, &buffer, buffer.count)
    guard bytesRead > 0,
          let raw = String(data: Data(buffer[0..<bytesRead]), encoding: .utf8) else {
        return 0
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = UInt32(trimmed) else {
        return 0
    }
    return uid_t(parsed)
}

private func disassociateDownstreamStation(_ downstream: String) {
    if let wifi = CWWiFiClient.shared().interface(withName: downstream) {
        if wifi.powerOn() {
            // Call unconditionally because root daemons without Location Services see ssid() == nil on macOS 14+.
            wifi.disassociate()
        } else {
            try? wifi.setPower(true)
        }
    }

    // Stop any 802.1X eapolclient bound only to the downstream Wi-Fi card; never touch wired upstream.
    let psOut = runBinary("/bin/ps", arguments: ["-axo", "pid=,args="])
    if psOut.succeeded {
        for rawLine in psOut.stdout.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(trimmed[..<firstSpace]),
                  pid > 1 else {
                continue
            }

            let cmdPart = String(trimmed[firstSpace...]).trimmingCharacters(in: .whitespaces)
            let tokens = cmdPart.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let executable = tokens.first,
                  executable == "eapolclient" || executable.hasSuffix("/eapolclient") else {
                continue
            }

            let argTokens = tokens.dropFirst()
            let matchesDownstream = argTokens.contains(where: { $0 == downstream || $0 == "-i\(downstream)" })
            if matchesDownstream {
                _ = Darwin.kill(pid, SIGTERM)
            }
        }
    }
}

private func detectBridgeSubnet() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard Darwin.getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { Darwin.freeifaddrs(ifaddr) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let ptr = cursor {
        let name = String(cString: ptr.pointee.ifa_name)
        if name == "bridge100",
           let sa = ptr.pointee.ifa_addr,
           sa.pointee.sa_family == UInt8(AF_INET),
           let maskSa = ptr.pointee.ifa_netmask,
           maskSa.pointee.sa_family == UInt8(AF_INET) {
            let ipVal = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let maskVal = maskSa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let prefix = maskVal.nonzeroBitCount
            if (8...30).contains(prefix) {
                let net = RouteConflictDetector.uInt32ToIPv4(ipVal & maskVal)
                return "\(net)/\(prefix)"
            }
        }
        cursor = ptr.pointee.ifa_next
    }
    return nil
}

private func lockSCPreferences(_ prefs: SCPreferences) -> Bool {
    for _ in 0..<5 {
        if SCPreferencesLock(prefs, false) {
            return true
        }
        if SCError() != Int32(kSCStatusPrefsBusy) {
            break
        }
        usleep(100_000)
    }
    writeStderr("SCPreferencesLock failed: \(String(cString: SCErrorString(SCError())))")
    return false
}

private func updateNATPreferences(_ mutate: (inout [String: Any]) -> Bool) -> Bool {
    guard let prefs = SCPreferencesCreate(nil, "com.netboost.helper" as CFString, "com.apple.nat.plist" as CFString) else {
        writeStderr("SCPreferencesCreate failed: \(String(cString: SCErrorString(SCError())))")
        return false
    }
    guard lockSCPreferences(prefs) else {
        return false
    }
    defer { SCPreferencesUnlock(prefs) }

    var natDict = (SCPreferencesGetValue(prefs, "NAT" as CFString) as? [String: Any]) ?? [:]
    guard mutate(&natDict) else {
        return true
    }
    guard SCPreferencesSetValue(prefs, "NAT" as CFString, natDict as CFDictionary) else {
        writeStderr("SCPreferencesSetValue failed: \(String(cString: SCErrorString(SCError())))")
        return false
    }
    guard SCPreferencesCommitChanges(prefs) else {
        writeStderr("SCPreferencesCommitChanges failed: \(String(cString: SCErrorString(SCError())))")
        return false
    }
    guard SCPreferencesApplyChanges(prefs) else {
        writeStderr("SCPreferencesApplyChanges failed: \(String(cString: SCErrorString(SCError())))")
        return false
    }
    return true
}

@discardableResult
private func applyNATPreferencesViaSCPreferences(_ natDict: [String: Any]) -> Bool {
    updateNATPreferences { current in
        current = natDict
        return true
    }
}

private func disableNATPreferences() {
    let updatedViaSC = updateNATPreferences { existing in
        guard !existing.isEmpty else { return false }
        existing["Enabled"] = 0
        return true
    }
    if !updatedViaSC {
        _ = runBinary("/usr/bin/defaults", arguments: ["write", "/Library/Preferences/SystemConfiguration/com.apple.nat", "NAT", "-dict-add", "Enabled", "-int", "0"])
    }
}

@discardableResult
private func flushPFAnchor(_ anchor: String) -> HelperResponse {
    let out = runBinary("/sbin/pfctl", arguments: ["-a", anchor, "-F", "all"])
    let lower = out.stderr.lowercased()
    if !out.succeeded && (lower.contains("does not exist") || lower.contains("no such")) {
        return HelperResponse(exitCode: 0, stdout: out.stdout)
    }
    return out
}

private func flushDNSAndResponder() -> HelperResponse {
    let dsOut = runBinary("/usr/bin/dscacheutil", arguments: ["-flushcache"])
    guard dsOut.succeeded else { return dsOut }
    let killOut = runBinary("/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
    if !killOut.succeeded && !killOut.stderr.contains("No matching processes") {
        return killOut
    }
    return HelperResponse(exitCode: 0, stdout: "DNS cache flushed.")
}

private func runSingleServiceNetworksetup(
    actionName: String,
    args: [String],
    networksetupArgs: (String) -> [String]
) -> HelperResponse {
    guard args.count == 1, HelperConstants.isValidSafeServiceName(args[0]) else {
        return HelperResponse(exitCode: 2, stderr: "Invalid service name for \(actionName)")
    }
    return runBinary("/usr/sbin/networksetup", arguments: networksetupArgs(args[0]))
}

private func prioritizeUpstreamForSharing(upstream: String, downstream: String) {
    let orderOutput = runBinary("/usr/sbin/networksetup", arguments: ["-listnetworkserviceorder"])
    if orderOutput.succeeded {
        let entries = ServiceOrderManager.parseServiceOrder(output: orderOutput.stdout)
            .filter { !$0.name.hasPrefix("*") }
        let names = entries.map(\.name)
        if let upstreamName = entries.first(where: { $0.device == upstream })?.name,
           names.first != upstreamName {
            var reordered = names.filter { $0 != upstreamName }
            reordered.insert(upstreamName, at: 0)
            _ = runBinary("/usr/sbin/networksetup", arguments: ["-ordernetworkservices"] + reordered)
        }
    }

    // Ensure shared traffic is not bottlenecked by a prior 1280 MTU cellular clamp.
    let downstreamService = resolveServiceName(downstream)
    if HelperConstants.isValidSafeServiceName(downstreamService) {
        _ = runBinary("/usr/sbin/networksetup", arguments: ["-setMTU", downstreamService, "1500"])
    }
}

private func handleHotspotStart(_ args: [String]) -> HelperResponse {
    guard args.count == 9 else {
        return HelperResponse(exitCode: 2, stderr: "hotspotStart requires 9 arguments")
    }

    let upstream = args[0]
    let downstream = args[1]
    let gateway = args[2]
    let subnet = args[3]
    let dhcpStart = args[4]
    let dhcpEnd = args[5]
    let ssid = args[6]
    let securityRaw = args[7]
    let password = args[8]

    guard HotspotNATController.isEligibleHotspotInterface(upstream),
          HotspotNATController.isEligibleHotspotInterface(downstream),
          upstream != downstream,
          HotspotNATController.isValidIPv4Address(gateway),
          HotspotNATController.isValidHotspotSubnetCIDR(subnet),
          HotspotNATController.isValidIPv4Address(dhcpStart),
          HotspotNATController.isValidIPv4Address(dhcpEnd),
          HotspotNATController.isIPv4(gateway, inCIDR: subnet),
          HotspotNATController.isIPv4(dhcpStart, inCIDR: subnet),
          HotspotNATController.isIPv4(dhcpEnd, inCIDR: subnet),
          let startInt = RouteConflictDetector.ipv4ToUInt32(dhcpStart),
          let endInt = RouteConflictDetector.ipv4ToUInt32(dhcpEnd),
          startInt <= endInt else {
        return HelperResponse(exitCode: 2, stderr: "Invalid hotspot network configuration parameters")
    }

    guard !ssid.isEmpty,
          ssid.utf8.count <= 32,
          !ssid.contains("\0"),
          !password.contains("\0") else {
        return HelperResponse(exitCode: 2, stderr: "Invalid hotspot SSID or password encoding")
    }

    let isOpenSecurity = (securityRaw == "Open")
    let parsedSecurity = HotspotSecurityType(rawValue: securityRaw)
    if isOpenSecurity {
        guard password.isEmpty else {
            return HelperResponse(exitCode: 2, stderr: "Open hotspot security must not include a password")
        }
    } else {
        guard parsedSecurity != nil, (8...63).contains(password.utf8.count) else {
            return HelperResponse(exitCode: 2, stderr: "Invalid hotspot security type or passphrase length (8-63 bytes required)")
        }
    }

    // Clear station 802.1X state on downstream Wi-Fi and ensure upstream wired LAN sits first with full MTU.
    disassociateDownstreamStation(downstream)
    _ = runBinary("/sbin/ifconfig", arguments: [downstream, "-alias", gateway])
    prioritizeUpstreamForSharing(upstream: upstream, downstream: downstream)

    let stagingDir = "\(HelperConstants.runtimeDirectory)/staging-\(UUID().uuidString)"
    guard ensureRootOwnedDirectory(stagingDir, mode: 0o700) else {
        return HelperResponse(exitCode: 1, stderr: "Failed to create secure staging directory")
    }
    defer { try? FileManager.default.removeItem(atPath: stagingDir) }

    let plistPath = "\(stagingDir)/com.apple.nat.plist"
    let rulesPath = "\(stagingDir)/netboost.pf"

    let effectiveSecurity = parsedSecurity ?? .wpa2Wpa3Transition
    let config = HotspotConfiguration(
        ssid: ssid,
        password: password,
        securityType: effectiveSecurity,
        subnet: subnet,
        gateway: gateway,
        dhcpRangeStart: dhcpStart,
        dhcpRangeEnd: dhcpEnd,
        interfaceName: downstream,
        upstreamInterface: upstream,
        isActive: true
    )
    var natDict = HotspotNATController.makeNATDictionary(
        configuration: config,
        upstreamInterface: upstream,
        downstreamInterface: downstream
    )
    if isOpenSecurity, var airport = natDict["AirPort"] as? [String: Any] {
        airport["SecurityType"] = "Open"
        natDict["AirPort"] = airport
    }

    do {
        let plistData = try PropertyListSerialization.data(fromPropertyList: ["NAT": natDict], format: .xml, options: 0)
        try plistData.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
    } catch {
        return HelperResponse(exitCode: 1, stderr: "Failed to serialize NAT plist: \(error.localizedDescription)")
    }

    let lintOut = runBinary("/usr/bin/plutil", arguments: ["-lint", plistPath])
    guard lintOut.succeeded else {
        return HelperResponse(exitCode: lintOut.exitCode, stdout: lintOut.stdout, stderr: "NAT plist lint failed: \(lintOut.stderr)")
    }

    if !applyNATPreferencesViaSCPreferences(natDict) {
        _ = runBinary("/usr/bin/defaults", arguments: ["import", "/Library/Preferences/SystemConfiguration/com.apple.nat", plistPath])
    }
    _ = runBinary("/bin/launchctl", arguments: ["kickstart", "-k", "system/com.apple.NetworkSharing"])

    // Wait briefly for macOS InternetSharing to spin up bridge100/ap1 before configuring PF anchors.
    for _ in 0..<10 {
        if DarwinSocketHelper.isInterfaceActive("bridge100") || DarwinSocketHelper.isInterfaceActive("ap1") {
            break
        }
        usleep(150_000)
    }

    let activeBridgeSubnet = detectBridgeSubnet()
    let primarySubnet = activeBridgeSubnet ?? subnet
    let pfManager = PFNATAnchorManager(
        anchorName: "netboost",
        upstreamInterface: upstream,
        clientSubnet: primarySubnet
    )

    let additionalSubnets = (activeBridgeSubnet != nil && activeBridgeSubnet != subnet) ? [subnet] : []
    let rules = pfManager.generateNATRules(additionalSubnets: additionalSubnets) + "\n"

    let rollbackHotspotSetup = {
        disableNATPreferences()
        _ = runBinary("/bin/launchctl", arguments: ["stop", "com.apple.NetworkSharing"])
        _ = flushPFAnchor(pfManager.anchorName)
        _ = flushPFAnchor(pfManager.appleAnchorName)
    }

    do {
        try rules.write(toFile: rulesPath, atomically: true, encoding: .utf8)
    } catch {
        rollbackHotspotSetup()
        return HelperResponse(exitCode: 1, stderr: "Failed to write PF rules: \(error.localizedDescription)")
    }

    let dryRunOut = runBinary("/sbin/pfctl", arguments: ["-nf", rulesPath])
    guard dryRunOut.succeeded else {
        rollbackHotspotSetup()
        return HelperResponse(exitCode: dryRunOut.exitCode, stdout: dryRunOut.stdout, stderr: "PF syntax check failed: \(dryRunOut.stderr)")
    }

    let loadPrimary = runBinary("/sbin/pfctl", arguments: ["-a", pfManager.anchorName, "-f", rulesPath])
    guard loadPrimary.succeeded else {
        rollbackHotspotSetup()
        return loadPrimary
    }

    let loadApple = runBinary("/sbin/pfctl", arguments: ["-a", pfManager.appleAnchorName, "-f", rulesPath])
    guard loadApple.succeeded else {
        rollbackHotspotSetup()
        return loadApple
    }

    let pfEnable = runBinary("/sbin/pfctl", arguments: ["-e"])
    if !pfEnable.succeeded && !pfEnable.stderr.lowercased().contains("already enabled") {
        rollbackHotspotSetup()
        return pfEnable
    }

    let sysctlOut = runBinary("/usr/sbin/sysctl", arguments: ["-w", "net.inet.ip.forwarding=1"])
    guard sysctlOut.succeeded else {
        rollbackHotspotSetup()
        return sysctlOut
    }

    _ = runBinary("/usr/bin/killall", arguments: ["-HUP", "bootpd"])
    _ = runBinary("/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])

    let broadcasting = DarwinSocketHelper.isInterfaceActive("bridge100") || DarwinSocketHelper.isInterfaceActive("ap1")
    let statusNote = broadcasting
        ? "Hotspot active and broadcasting (\(upstream) -> \(downstream), bridge100 up)"
        : "Hotspot NAT/forwarding armed on \(upstream) (awaiting macOS Internet Sharing SoftAP)"
    return HelperResponse(exitCode: 0, stdout: statusNote)
}

private func handleHotspotStop(_ args: [String]) -> HelperResponse {
    guard (1...2).contains(args.count) else {
        return HelperResponse(exitCode: 2, stderr: "hotspotStop requires [downstream] or [downstream, gateway]")
    }
    let downstream = args[0]
    let gateway = args.count == 2 ? args[1] : "192.168.2.1"

    guard HotspotNATController.isEligibleHotspotInterface(downstream),
          HotspotNATController.isValidIPv4Address(gateway) else {
        return HelperResponse(exitCode: 2, stderr: "Invalid hotspot stop parameters")
    }

    disableNATPreferences()

    _ = runBinary("/bin/launchctl", arguments: ["stop", "com.apple.NetworkSharing"])
    _ = flushPFAnchor("netboost")
    _ = flushPFAnchor("com.apple/netboost")
    _ = runBinary("/sbin/ifconfig", arguments: [downstream, "-alias", gateway])
    let sysctlOut = runBinary("/usr/sbin/sysctl", arguments: ["-w", "net.inet.ip.forwarding=0"])
    guard sysctlOut.succeeded else {
        return sysctlOut
    }
    return HelperResponse(exitCode: 0, stdout: "Hotspot NAT anchors flushed and IP forwarding disabled")
}

private func handleAction(_ request: HelperRequest) -> HelperResponse {
    let args = request.arguments

    switch request.action {
    case .ping:
        guard args.isEmpty else {
            return HelperResponse(exitCode: 2, stderr: "ping takes no arguments")
        }
        return HelperResponse(exitCode: 0, stdout: HelperConstants.protocolVersion)

    case .status:
        guard args.isEmpty else {
            return HelperResponse(exitCode: 2, stderr: "status takes no arguments")
        }
        let sysctlOut = runBinary("/usr/sbin/sysctl", arguments: ["net.inet.ip.forwarding"])
        let pfOut = runBinary("/sbin/pfctl", arguments: ["-s", "info"])
        let pfSnippet = pfOut.stdout.components(separatedBy: .newlines).prefix(5).joined(separator: "\n")
        let combined = [
            "NetBoost Helper: Active (root daemon v\(HelperConstants.protocolVersion))",
            sysctlOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            pfSnippet
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        return HelperResponse(exitCode: 0, stdout: combined)

    default:
        break
    }

    systemMutationLock.lock()
    defer { systemMutationLock.unlock() }

    switch request.action {
    case .ping, .status:
        return HelperResponse(exitCode: 0)

    case .setIPForwarding:
        guard args.count == 1, args[0] == "0" || args[0] == "1" else {
            return HelperResponse(exitCode: 2, stderr: "setIPForwarding requires '0' or '1'")
        }
        return runBinary("/usr/sbin/sysctl", arguments: ["-w", "net.inet.ip.forwarding=\(args[0])"])

    case .pfEnable:
        guard args.isEmpty else {
            return HelperResponse(exitCode: 2, stderr: "pfEnable takes no arguments")
        }
        let out = runBinary("/sbin/pfctl", arguments: ["-e"])
        if !out.succeeded && out.stderr.lowercased().contains("already enabled") {
            return HelperResponse(exitCode: 0, stdout: out.stdout)
        }
        return out

    case .pfDisable:
        guard args.isEmpty else {
            return HelperResponse(exitCode: 2, stderr: "pfDisable takes no arguments")
        }
        let out = runBinary("/sbin/pfctl", arguments: ["-d"])
        let lower = out.stderr.lowercased()
        if !out.succeeded && (lower.contains("not enabled") || lower.contains("disabled")) {
            return HelperResponse(exitCode: 0, stdout: out.stdout)
        }
        return out

    case .pfFlushAnchor:
        guard args.count <= 1 else {
            return HelperResponse(exitCode: 2, stderr: "pfFlushAnchor accepts at most 1 argument")
        }
        let anchor = args.first ?? "netboost"
        guard HelperConstants.isValidAnchorName(anchor) else {
            return HelperResponse(exitCode: 2, stderr: "Invalid PF anchor name '\(anchor)'")
        }
        return flushPFAnchor(anchor)

    case .setMTU:
        guard args.count == 2 else {
            return HelperResponse(exitCode: 2, stderr: "setMTU requires [serviceOrInterface, mtu]")
        }
        guard HelperConstants.isValidSafeServiceName(args[0]),
              HelperConstants.isValidMTUString(args[1]) else {
            return HelperResponse(exitCode: 2, stderr: "Invalid service name or MTU")
        }
        let resolvedService = resolveServiceName(args[0])
        return runBinary("/usr/sbin/networksetup", arguments: ["-setMTU", resolvedService, args[1]])

    case .flushDNS:
        guard args.isEmpty else {
            return HelperResponse(exitCode: 2, stderr: "flushDNS takes no arguments")
        }
        return flushDNSAndResponder()

    case .flushARP:
        guard args.count <= 1 else {
            return HelperResponse(exitCode: 2, stderr: "flushARP accepts at most 1 argument")
        }
        if let ip = args.first {
            guard RoutePinningEngine.validateIPv4(ip) else {
                return HelperResponse(exitCode: 2, stderr: "Invalid IPv4 address '\(ip)'")
            }
            let out = runBinary("/usr/sbin/arp", arguments: ["-d", ip])
            if !out.succeeded && out.stderr.lowercased().contains("cannot locate") {
                return HelperResponse(exitCode: 0, stdout: out.stdout)
            }
            return out
        } else {
            let out = runBinary("/usr/sbin/arp", arguments: ["-d", "-a"])
            if !out.succeeded && out.stderr.lowercased().contains("cannot locate") {
                return HelperResponse(exitCode: 0, stdout: out.stdout)
            }
            return out
        }

    case .disableIPv6:
        return runSingleServiceNetworksetup(actionName: "disableIPv6", args: args) { ["-setv6off", $0] }

    case .enableIPv6:
        return runSingleServiceNetworksetup(actionName: "enableIPv6", args: args) { ["-setv6automatic", $0] }

    case .resetDNS:
        return runSingleServiceNetworksetup(actionName: "resetDNS", args: args) { ["-setdnsservers", $0, "Empty"] }

    case .setCampusDNS:
        return runSingleServiceNetworksetup(actionName: "setCampusDNS", args: args) { ["-setdnsservers", $0, "10.4.20.21", "10.4.20.222"] }

    case .cleanProxies:
        guard args.count == 1, HelperConstants.isValidSafeServiceName(args[0]) else {
            return HelperResponse(exitCode: 2, stderr: "Invalid service name for cleanProxies")
        }
        for flag in ["-setautoproxystate", "-setwebproxystate", "-setsecurewebproxystate"] {
            let out = runBinary("/usr/sbin/networksetup", arguments: [flag, args[0], "off"])
            guard out.succeeded else { return out }
        }
        return HelperResponse(exitCode: 0, stdout: "Cleaned proxies for \(args[0])")

    case .isolateRelay:
        return runSingleServiceNetworksetup(actionName: "isolateRelay", args: args) { ["-setproxybypassdomains", $0, "*.mask.icloud.com", "*.mask-h2.icloud.com"] }

    case .restoreRelay:
        return runSingleServiceNetworksetup(actionName: "restoreRelay", args: args) { ["-setproxybypassdomains", $0, "Empty"] }

    case .batchAutoFix:
        guard args.count <= 2 else {
            return HelperResponse(exitCode: 2, stderr: "batchAutoFix accepts [service, mtu]")
        }
        let targetService = args.first ?? "Wi-Fi"
        let mtuStr = args.count == 2 ? args[1] : String(MTUManager.cellularOptimalMTU)
        guard HelperConstants.isValidSafeServiceName(targetService),
              HelperConstants.isValidMTUString(mtuStr) else {
            return HelperResponse(exitCode: 2, stderr: "Invalid service name or MTU for batchAutoFix")
        }
        let resolvedService = resolveServiceName(targetService)
        let mtuOut = runBinary("/usr/sbin/networksetup", arguments: ["-setMTU", resolvedService, mtuStr])
        guard mtuOut.succeeded else { return mtuOut }

        let dnsOut = flushDNSAndResponder()
        guard dnsOut.succeeded else { return dnsOut }

        _ = runBinary("/usr/sbin/arp", arguments: ["-d", "-a"])
        return HelperResponse(exitCode: 0, stdout: "Batch Auto-Fix complete for '\(resolvedService)' (MTU \(mtuStr))")

    case .orderServices:
        guard !args.isEmpty, args.allSatisfy(HelperConstants.isValidSafeServiceName) else {
            return HelperResponse(exitCode: 2, stderr: "Invalid or empty service list for orderServices")
        }
        return runBinary("/usr/sbin/networksetup", arguments: ["-ordernetworkservices"] + args)

    case .pinRoute:
        guard args.count == 3 else {
            return HelperResponse(exitCode: 2, stderr: "pinRoute requires [subnet, gateway, interface]")
        }
        let (subnet, gateway, iface) = (args[0], args[1], args[2])
        guard (RoutePinningEngine.validateCIDR(subnet) || RoutePinningEngine.validateIPv4(subnet)),
              RoutePinningEngine.validateIPv4(gateway),
              RoutePinningEngine.validateInterface(iface) else {
            return HelperResponse(exitCode: 2, stderr: "Invalid route parameters for pinRoute")
        }
        let routeArgs = routeArguments(action: "add", subnet: subnet, gateway: gateway, interface: iface)
        return runBinary("/sbin/route", arguments: routeArgs)

    case .unpinRoute:
        guard args.count == 2 else {
            return HelperResponse(exitCode: 2, stderr: "unpinRoute requires [subnet, gateway]")
        }
        let (subnet, gateway) = (args[0], args[1])
        guard (RoutePinningEngine.validateCIDR(subnet) || RoutePinningEngine.validateIPv4(subnet)),
              RoutePinningEngine.validateIPv4(gateway) else {
            return HelperResponse(exitCode: 2, stderr: "Invalid route parameters for unpinRoute")
        }
        let routeArgs = routeArguments(action: "delete", subnet: subnet, gateway: gateway, interface: nil)
        return runBinary("/sbin/route", arguments: routeArgs)

    case .hotspotStart:
        return handleHotspotStart(args)

    case .hotspotStop:
        return handleHotspotStop(args)
    }
}

private func writeAll(fd: Int32, data: Data) {
    data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var written = 0
        while written < rawBuffer.count {
            let n = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            if n == 0 { return }
            written += n
        }
    }
}

private func sendResponseAndClose(fd: Int32, response: HelperResponse) {
    defer { Darwin.close(fd) }
    let encoder = JSONEncoder()
    guard var data = try? encoder.encode(response) else { return }
    data.append(0x0A)
    writeAll(fd: fd, data: data)
}

private func handleClientConnection(fd clientFd: Int32) {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = Darwin.setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = Darwin.setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    var sawNewline = false

    while true {
        let bytesRead = chunk.withUnsafeMutableBytes { raw -> Int in
            Darwin.read(clientFd, raw.baseAddress, raw.count)
        }
        if bytesRead < 0 {
            if errno == EINTR { continue }
            Darwin.close(clientFd)
            return
        }
        if bytesRead == 0 {
            break
        }

        if let nlIndex = chunk[0..<bytesRead].firstIndex(of: 0x0A) {
            buffer.append(contentsOf: chunk[0..<nlIndex])
            sawNewline = true
        } else {
            buffer.append(contentsOf: chunk[0..<bytesRead])
        }

        if buffer.count > HelperConstants.maxPayloadBytes {
            sendResponseAndClose(
                fd: clientFd,
                response: HelperResponse(exitCode: 2, stderr: "Request exceeds \(HelperConstants.maxPayloadBytes) byte limit")
            )
            return
        }

        if sawNewline {
            break
        }
    }

    guard !buffer.isEmpty else {
        sendResponseAndClose(fd: clientFd, response: HelperResponse(exitCode: 2, stderr: "Empty request payload"))
        return
    }

    let request: HelperRequest
    do {
        request = try JSONDecoder().decode(HelperRequest.self, from: buffer)
    } catch {
        sendResponseAndClose(fd: clientFd, response: HelperResponse(exitCode: 2, stderr: "Malformed request JSON"))
        return
    }

    guard request.version == HelperConstants.protocolVersion else {
        sendResponseAndClose(
            fd: clientFd,
            response: HelperResponse(
                exitCode: 2,
                stderr: "Protocol version mismatch: expected \(HelperConstants.protocolVersion), got \(request.version)"
            )
        )
        return
    }

    let response = handleAction(request)
    sendResponseAndClose(fd: clientFd, response: response)
}

private func runDaemon() -> Int32 {
    guard geteuid() == 0 else {
        writeStderr("Error: NetBoostHelper --daemon must run as root (euid 0).")
        return 1
    }

    _ = Darwin.signal(SIGPIPE, SIG_IGN)

    guard ensureRootOwnedDirectory(HelperConstants.runtimeDirectory, mode: 0o755) else {
        writeStderr("Error: Failed to prepare root-owned runtime directory at \(HelperConstants.runtimeDirectory).")
        return 1
    }

    let authorizedUID = readAuthorizedUID()

    _ = Darwin.unlink(HelperConstants.socketPath)

    let serverFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverFd >= 0 else {
        writeStderr("Error: socket(AF_UNIX) failed with errno \(errno).")
        return 1
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(HelperConstants.socketPath.utf8CString)
    let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= sunPathCapacity else {
        writeStderr("Error: Socket path exceeds sun_path limit.")
        Darwin.close(serverFd)
        return 1
    }

    withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
        rawBuf.initializeMemory(as: UInt8.self, repeating: 0)
        for (idx, cChar) in pathBytes.enumerated() {
            rawBuf[idx] = UInt8(bitPattern: cChar)
        }
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let previousUmask = Darwin.umask(0o177)
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.bind(serverFd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    _ = Darwin.umask(previousUmask)
    guard bindResult == 0 else {
        writeStderr("Error: bind(\(HelperConstants.socketPath)) failed with errno \(errno).")
        Darwin.close(serverFd)
        return 1
    }

    let staffGid: gid_t = {
        if let grp = getgrnam("staff") {
            return grp.pointee.gr_gid
        }
        return 20
    }()

    guard Darwin.chown(HelperConstants.socketPath, 0, staffGid) == 0,
          Darwin.chmod(HelperConstants.socketPath, 0o660) == 0 else {
        writeStderr("Error: Failed to set socket ownership/permissions (errno \(errno)).")
        Darwin.close(serverFd)
        return 1
    }

    guard Darwin.listen(serverFd, 32) == 0 else {
        writeStderr("Error: listen() failed with errno \(errno).")
        Darwin.close(serverFd)
        return 1
    }

    let clientQueue = DispatchQueue(label: "com.netboost.helper.clients", attributes: .concurrent)

    while true {
        let clientFd = Darwin.accept(serverFd, nil, nil)
        if clientFd < 0 {
            if errno == EINTR { continue }
            writeStderr("Error: accept() failed with errno \(errno).")
            break
        }

        // Authenticate peer UID via kernel credential before reading any bytes.
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let credOk = Darwin.getsockopt(clientFd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen) == 0
        let validPeer = credOk
            && credLen >= socklen_t(MemoryLayout<xucred>.size)
            && cred.cr_version == UInt32(XUCRED_VERSION)
            && (cred.cr_uid == authorizedUID || cred.cr_uid == 0)

        guard validPeer else {
            Darwin.close(clientFd)
            continue
        }

        clientQueue.async {
            handleClientConnection(fd: clientFd)
        }
    }

    Darwin.close(serverFd)
    return 1
}

let args = CommandLine.arguments
if args.contains("--version") {
    print(HelperConstants.protocolVersion)
    exit(0)
} else if args.contains("--daemon") {
    exit(runDaemon())
} else {
    writeStderr("Usage: \(args.first ?? "NetBoostHelper") [--version | --daemon]")
    exit(2)
}
