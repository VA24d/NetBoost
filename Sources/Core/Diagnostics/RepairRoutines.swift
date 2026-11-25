import Foundation

internal protocol PrivilegeCommandExecuting: Sendable {
    var isRoot: Bool { get }
    func locateHelperScript() -> String?
    func runCommand(_ executable: String, arguments: [String]) async throws -> ShellOutput
    func runBash(_ script: String) async throws -> ShellOutput
    func runElevated(script: String) async throws -> ShellOutput
    func runHelper(action: String, arguments: [String]) async throws -> ShellOutput
    func runDaemonAction(action: HelperAction, arguments: [String]) async throws -> ShellOutput?
}

internal extension PrivilegeCommandExecuting {
    func runDaemonAction(action: HelperAction, arguments: [String]) async throws -> ShellOutput? {
        nil
    }

    func executeElevatedWithFallback(
        daemonAction: HelperAction?,
        daemonArguments: [String],
        fallbackScript: String,
        helperAction: String?,
        helperArguments: [String]
    ) async throws {
        if let daemonAction {
            do {
                if let daemonOutput = try await runDaemonAction(action: daemonAction, arguments: daemonArguments) {
                    guard daemonOutput.succeeded else {
                        throw PrivilegeError.executionFailed(daemonOutput.stderr)
                    }
                    return
                }
            } catch PrivilegeError.helperNotFound {
                // Fall back to legacy osascript / helper script when daemon is unavailable.
            }
        }

        do {
            _ = try await runElevated(script: fallbackScript)
        } catch PrivilegeError.elevationDenied {
            throw PrivilegeError.elevationDenied
        } catch {
            guard let action = helperAction, locateHelperScript() != nil else {
                throw error
            }
            _ = try await runHelper(action: action, arguments: helperArguments)
        }
    }
}

internal struct SystemPrivilegeCommandExecutor: PrivilegeCommandExecuting {
    var isRoot: Bool { PrivilegeHelper.isRoot }

    func locateHelperScript() -> String? {
        PrivilegeHelper.locateHelperScript()
    }

    func runCommand(_ executable: String, arguments: [String]) async throws -> ShellOutput {
        try await ShellCommand.run(executable, arguments: arguments)
    }

    func runBash(_ script: String) async throws -> ShellOutput {
        try await ShellCommand.runBash(script)
    }

    func runElevated(script: String) async throws -> ShellOutput {
        try await PrivilegeHelper.runElevated(script: script)
    }

    func runHelper(action: String, arguments: [String]) async throws -> ShellOutput {
        try await PrivilegeHelper.runHelper(action: action, arguments: arguments)
    }

    func runDaemonAction(action: HelperAction, arguments: [String]) async throws -> ShellOutput? {
        guard PrivilegeHelper.locateBundledOrBuiltHelperExecutable() != nil || PrivilegeHelper.isHelperDaemonInstalled else {
            return nil
        }
        return try await PrivilegeHelper.runDaemonAction(action: action, arguments: arguments)
    }
}

/// Coordinates system remediation actions for DNS, ARP, IPv6, and Web Proxies.
public final class RepairRoutines: @unchecked Sendable {

    private var auditLog: [String] = []
    private let lock = NSLock()
    private let executor: any PrivilegeCommandExecuting

    public init() {
        self.executor = SystemPrivilegeCommandExecutor()
    }

    internal init(executor: any PrivilegeCommandExecuting) {
        self.executor = executor
    }

    public var history: [String] {
        lock.lock()
        defer { lock.unlock() }
        return auditLog
    }

    public func recordEvent(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        auditLog.append("[\(Date())] \(message)")
    }

    // MARK: - Quoted Shell Script Builders

    public static func shellCommandString(_ args: [String]) -> String {
        args.map(ShellCommand.shellQuote).joined(separator: " ")
    }

    public static func makeBatchAutoFixScript(service: String = "Wi-Fi", mtu: Int = 1280) -> String {
        let (dns1, dns2) = DNSFlushRoutine.makeCommands()
        let arpCmd = ARPFlushRoutine.makeFlushAllCommand()
        let mtuCmd = ["/usr/sbin/networksetup", "-setMTU", service, String(mtu)]
        return [mtuCmd, dns1, dns2, arpCmd]
            .map { shellCommandString($0) }
            .joined(separator: " && ")
    }

    public static func makeCleanProxiesScript(service: String) -> String {
        let cmd1 = ProxySettingsManager.makeDisableAutoProxyCommand(service: service)
        let cmd2 = ProxySettingsManager.makeDisableWebProxyCommand(service: service)
        let cmd3 = ProxySettingsManager.makeDisableSecureWebProxyCommand(service: service)
        return [cmd1, cmd2, cmd3]
            .map { shellCommandString($0) }
            .joined(separator: " && ")
    }

    private func executePrivileged(
        command: [String],
        daemonAction: HelperAction? = nil,
        helperAction: String? = nil,
        helperArguments: [String] = []
    ) async throws {
        if executor.isRoot {
            guard let executable = command.first else {
                throw ShellError.processError("Empty command")
            }
            let output = try await executor.runCommand(executable, arguments: Array(command.dropFirst()))
            guard output.succeeded else {
                throw ShellError.executionFailed(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
            }
            return
        }

        let quotedScript = Self.shellCommandString(command)
        try await executor.executeElevatedWithFallback(
            daemonAction: daemonAction,
            daemonArguments: helperArguments,
            fallbackScript: quotedScript,
            helperAction: helperAction,
            helperArguments: helperArguments
        )
    }

    private func executePrivilegedScript(
        _ script: String,
        daemonAction: HelperAction? = nil,
        helperAction: String? = nil,
        helperArguments: [String] = []
    ) async throws {
        if executor.isRoot {
            let output = try await executor.runBash(script)
            guard output.succeeded else {
                throw ShellError.executionFailed(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
            }
            return
        }

        try await executor.executeElevatedWithFallback(
            daemonAction: daemonAction,
            daemonArguments: helperArguments,
            fallbackScript: script,
            helperAction: helperAction,
            helperArguments: helperArguments
        )
    }

    // MARK: - DNS Cache Flush

    public func flushDNS() async throws {
        let (cmd1, cmd2) = DNSFlushRoutine.makeCommands()
        if executor.isRoot {
            let out1 = try await executor.runCommand(cmd1[0], arguments: Array(cmd1.dropFirst()))
            guard out1.succeeded else {
                throw ShellError.executionFailed(exitCode: out1.exitCode, stdout: out1.stdout, stderr: out1.stderr)
            }
            let out2 = try await executor.runCommand(cmd2[0], arguments: Array(cmd2.dropFirst()))
            guard out2.succeeded else {
                throw ShellError.executionFailed(exitCode: out2.exitCode, stdout: out2.stdout, stderr: out2.stderr)
            }
        } else {
            // dscacheutil can be run unprivileged; mDNSResponder requires elevation or helper
            _ = try? await executor.runCommand(cmd1[0], arguments: Array(cmd1.dropFirst()))
            let combined = "\(Self.shellCommandString(cmd1)) && \(Self.shellCommandString(cmd2))"
            try await executePrivilegedScript(combined, daemonAction: .flushDNS, helperAction: "flush-dns")
        }
        recordEvent("DNS cache flushed (dscacheutil + killall mDNSResponder)")
    }

    /// Executes MTU adjustment, DNS flush, and ARP table flush in a single elevation pass so the user is prompted at most ONCE.
    public func executeBatchAutoFix(service: String = "Wi-Fi", mtu: Int = 1280) async throws {
        let combined = Self.makeBatchAutoFixScript(service: service, mtu: mtu)
        try await executePrivilegedScript(
            combined,
            daemonAction: .batchAutoFix,
            helperAction: "batch-autofix",
            helperArguments: [service, String(mtu)]
        )
        recordEvent("Batch Auto-Fix executed: MTU set to \(mtu), DNS flushed, ARP cleared (single elevation)")
    }

    // MARK: - ARP Cache Flush

    public func flushARP(targetIP: String? = nil) async throws {
        let cmd = targetIP != nil ? ARPFlushRoutine.makeFlushHostCommand(ip: targetIP!) : ARPFlushRoutine.makeFlushAllCommand()
        try await executePrivileged(
            command: cmd,
            daemonAction: .flushARP,
            helperAction: targetIP == nil ? "flush-arp" : nil,
            helperArguments: targetIP.map { [$0] } ?? []
        )
        recordEvent("ARP table flushed (\(targetIP ?? "all entries"))")
    }

    // MARK: - DNS Overrides Reset

    public func resetDNS(service: String) async throws {
        let cmd = DNSOverrideManager.makeResetDNSCommand(service: service)
        try await executePrivileged(
            command: cmd,
            daemonAction: .resetDNS,
            helperAction: "reset-dns",
            helperArguments: [service]
        )
        recordEvent("DNS servers for '\(service)' reset to DHCP defaults")
    }

    public func setCampusDNS(service: String) async throws {
        let cmd = DNSOverrideManager.makeSetCampusDNSCommand(service: service)
        try await executePrivileged(
            command: cmd,
            daemonAction: .setCampusDNS,
            helperArguments: [service]
        )
        recordEvent("DNS servers for '\(service)' configured to campus resolvers 10.4.20.21, 10.4.20.222")
    }

    // MARK: - IPv6 Disabler (Happy Eyeballs fix)

    public func disableIPv6(service: String) async throws {
        let cmd = IPv6Manager.makeDisableIPv6Command(service: service)
        try await executePrivileged(
            command: cmd,
            daemonAction: .disableIPv6,
            helperAction: "disable-ipv6",
            helperArguments: [service]
        )
        recordEvent("IPv6 disabled on service '\(service)' to eliminate Happy Eyeballs latency")
    }

    public func enableIPv6(service: String) async throws {
        let cmd = IPv6Manager.makeEnableIPv6AutomaticCommand(service: service)
        try await executePrivileged(
            command: cmd,
            daemonAction: .enableIPv6,
            helperArguments: [service]
        )
        recordEvent("IPv6 restored to Automatic on service '\(service)'")
    }

    // MARK: - Proxy Cleaner

    public func cleanProxies(service: String) async throws {
        if executor.isRoot {
            let cmd1 = ProxySettingsManager.makeDisableAutoProxyCommand(service: service)
            let cmd2 = ProxySettingsManager.makeDisableWebProxyCommand(service: service)
            let cmd3 = ProxySettingsManager.makeDisableSecureWebProxyCommand(service: service)
            for cmd in [cmd1, cmd2, cmd3] {
                let output = try await executor.runCommand(cmd[0], arguments: Array(cmd.dropFirst()))
                guard output.succeeded else {
                    throw ShellError.executionFailed(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
                }
            }
        } else {
            let combined = Self.makeCleanProxiesScript(service: service)
            try await executePrivilegedScript(
                combined,
                daemonAction: .cleanProxies,
                helperAction: "clean-proxies",
                helperArguments: [service]
            )
        }
        recordEvent("Cleaned auto-proxy PAC and web proxy settings on '\(service)'")
    }

    // MARK: - Per-Adapter Private Relay Management

    /// Checks if Private Relay is specifically isolated (bypassed/disabled) on the given service.
    public func isPrivateRelayIsolated(service: String) async -> Bool {
        let bypassCmd = PrivateRelayManager.makeInspectProxyBypassCommand(service: service)
        if let bypassOut = try? await executor.runCommand(bypassCmd[0], arguments: Array(bypassCmd.dropFirst())),
           bypassOut.succeeded,
           PrivateRelayManager.parsePrivateRelayBypassStatus(output: bypassOut.stdout) {
            return true
        }

        let cmd = PrivateRelayManager.makeInspectServiceProxiesCommand(service: service)
        let output = (try? await executor.runCommand(cmd[0], arguments: Array(cmd.dropFirst())))?.stdout ?? ""
        return PrivateRelayManager.parsePrivateRelayBypassStatus(output: output)
    }

    /// Disables Private Relay on the target campus service (e.g. en10) while preserving it on other adapters.
    public func isolatePrivateRelay(for service: String) async throws {
        let cmd = PrivateRelayManager.makeDisablePrivateRelayCanaryCommand(service: service)
        try await executePrivileged(
            command: cmd,
            daemonAction: .isolateRelay,
            helperAction: "isolate-relay",
            helperArguments: [service]
        )
        recordEvent("iCloud Private Relay isolated on '\(service)' to avoid campus portal/MTU interference")
    }

    /// Restores Private Relay configuration on the target service.
    public func restorePrivateRelay(for service: String) async throws {
        let cmd = PrivateRelayManager.makeRestorePrivateRelayCanaryCommand(service: service)
        try await executePrivileged(
            command: cmd,
            daemonAction: .restoreRelay,
            helperAction: "restore-relay",
            helperArguments: [service]
        )
        recordEvent("iCloud Private Relay restored on '\(service)'")
    }
}

// MARK: - Component Structures for Direct Access

public struct DNSFlushRoutine: Sendable {
    public static func makeCommands() -> (dscacheutil: [String], killall: [String]) {
        (
            ["/usr/bin/dscacheutil", "-flushcache"],
            ["/usr/bin/killall", "-HUP", "mDNSResponder"]
        )
    }

    public static func execute(runner: Any? = nil) async throws {
        let (cmd1, cmd2) = makeCommands()
        _ = try await ShellCommand.run(cmd1[0], arguments: Array(cmd1.dropFirst()))
        _ = try await ShellCommand.run(cmd2[0], arguments: Array(cmd2.dropFirst()))
    }
}

public struct ARPFlushRoutine: Sendable {
    public static func makeFlushAllCommand() -> [String] {
        ["/usr/sbin/arp", "-d", "-a"]
    }

    public static func makeFlushHostCommand(ip: String) -> [String] {
        ["/usr/sbin/arp", "-d", ip]
    }

    public static func parseARPTable(output: String) -> [(ip: String, mac: String)] {
        var entries: [(ip: String, mac: String)] = []
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            // "? (10.1.36.1) at 00:00:0c:07:ac:01 on en10 ifscope [ethernet]"
            if let startParen = line.firstIndex(of: "("),
               let endParen = line.firstIndex(of: ")"),
               let atRange = line.range(of: " at ") {
                let ip = String(line[line.index(after: startParen)..<endParen])
                let remainder = line[atRange.upperBound...]
                let mac = String(remainder.split(separator: " ").first ?? "")
                entries.append((ip: ip, mac: mac))
            }
        }
        return entries
    }
}

public struct DNSOverrideManager: Sendable {
    public static func makeResetDNSCommand(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-setdnsservers", service, "Empty"]
    }

    public static func makeSetCampusDNSCommand(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-setdnsservers", service, "10.4.20.21", "10.4.20.222"]
    }

    public static func parseGetDNSServersOutput(_ output: String) -> [String] {
        if output.contains("There aren't any DNS Servers set") {
            return []
        }
        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public struct IPv6Manager: Sendable {
    public static func makeDisableIPv6Command(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-setv6off", service]
    }

    public static func makeEnableIPv6AutomaticCommand(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-setv6automatic", service]
    }

    public static func parseIPv6State(fromGetInfo output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix("IPv6:") {
                return line.replacingOccurrences(of: "IPv6:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return "Unknown"
    }
}

public struct ProxySettingsManager: Sendable {
    public static func makeDisableAutoProxyCommand(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-setautoproxystate", service, "off"]
    }

    public static func makeDisableWebProxyCommand(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-setwebproxystate", service, "off"]
    }

    public static func makeDisableSecureWebProxyCommand(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-setsecurewebproxystate", service, "off"]
    }

    public static func parseProxyState(output: String) -> Bool {
        output.lowercased().contains("enabled: yes")
    }
}

// MARK: - iCloud Private Relay Per-Adapter Isolation

public struct PrivateRelayManager: Sendable {
    /// Generates shell command to inspect whether a network service has custom proxy or resolver configurations.
    public static func makeInspectServiceProxiesCommand(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-getwebproxy", service]
    }

    /// Generates shell command to inspect proxy bypass domains configured on a network service.
    public static func makeInspectProxyBypassCommand(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-getproxybypassdomains", service]
    }

    /// Generates shell command to disable Apple Private Relay on a specific service by configuring localized DNS canary block.
    public static func makeDisablePrivateRelayCanaryCommand(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-setproxybypassdomains", service, "*.mask.icloud.com", "*.mask-h2.icloud.com"]
    }

    /// Generates shell command to clear Private Relay canary bypass domains.
    public static func makeRestorePrivateRelayCanaryCommand(service: String) -> [String] {
        ["/usr/sbin/networksetup", "-setproxybypassdomains", service, "Empty"]
    }

    /// Evaluates whether Private Relay canary bypass domains are present in networksetup output.
    public static func parsePrivateRelayBypassStatus(output: String) -> Bool {
        output.contains("mask.icloud.com")
    }
}
