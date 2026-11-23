import Foundation

/// Coordinates system remediation actions for DNS, ARP, IPv6, and Web Proxies.
public final class RepairRoutines: @unchecked Sendable {

    private var auditLog: [String] = []
    private let lock = NSLock()

    public init() {}

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

    // MARK: - DNS Cache Flush

    public func flushDNS() async throws {
        let (cmd1, cmd2) = DNSFlushRoutine.makeCommands()
        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd1[0], arguments: Array(cmd1.dropFirst()))
            _ = try await ShellCommand.run(cmd2[0], arguments: Array(cmd2.dropFirst()))
        } else {
            // dscacheutil can be run unprivileged; mDNSResponder requires elevation or helper
            _ = try? await ShellCommand.run(cmd1[0], arguments: Array(cmd1.dropFirst()))
            do {
                _ = try await PrivilegeHelper.runElevated(script: "\(cmd1.joined(separator: " ")) && \(cmd2.joined(separator: " "))")
            } catch {
                // If helper is present, try helper
                _ = try? await PrivilegeHelper.runHelper(action: "flush-dns")
            }
        }
        recordEvent("DNS cache flushed (dscacheutil + killall mDNSResponder)")
    }

    // MARK: - ARP Cache Flush

    public func flushARP(targetIP: String? = nil) async throws {
        let cmd = targetIP != nil ? ARPFlushRoutine.makeFlushHostCommand(ip: targetIP!) : ARPFlushRoutine.makeFlushAllCommand()
        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: cmd[0], arguments: Array(cmd.dropFirst()))
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "flush-arp")
            }
        }
        recordEvent("ARP table flushed (\(targetIP ?? "all entries"))")
    }

    // MARK: - DNS Overrides Reset

    public func resetDNS(service: String) async throws {
        let cmd = DNSOverrideManager.makeResetDNSCommand(service: service)
        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: cmd[0], arguments: Array(cmd.dropFirst()))
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "reset-dns", arguments: [service])
            }
        }
        recordEvent("DNS servers for '\(service)' reset to DHCP defaults")
    }

    public func setCampusDNS(service: String) async throws {
        let cmd = DNSOverrideManager.makeSetCampusDNSCommand(service: service)
        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        } else {
            _ = try await PrivilegeHelper.runElevated(script: cmd[0], arguments: Array(cmd.dropFirst()))
        }
        recordEvent("DNS servers for '\(service)' configured to campus resolvers 10.4.20.21, 10.4.20.222")
    }

    // MARK: - IPv6 Disabler (Happy Eyeballs fix)

    public func disableIPv6(service: String) async throws {
        let cmd = IPv6Manager.makeDisableIPv6Command(service: service)
        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: cmd[0], arguments: Array(cmd.dropFirst()))
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "disable-ipv6", arguments: [service])
            }
        }
        recordEvent("IPv6 disabled on service '\(service)' to eliminate Happy Eyeballs latency")
    }

    public func enableIPv6(service: String) async throws {
        let cmd = IPv6Manager.makeEnableIPv6AutomaticCommand(service: service)
        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        } else {
            _ = try await PrivilegeHelper.runElevated(script: cmd[0], arguments: Array(cmd.dropFirst()))
        }
        recordEvent("IPv6 restored to Automatic on service '\(service)'")
    }

    // MARK: - Proxy Cleaner

    public func cleanProxies(service: String) async throws {
        let cmd1 = ProxySettingsManager.makeDisableAutoProxyCommand(service: service)
        let cmd2 = ProxySettingsManager.makeDisableWebProxyCommand(service: service)
        let cmd3 = ProxySettingsManager.makeDisableSecureWebProxyCommand(service: service)

        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd1[0], arguments: Array(cmd1.dropFirst()))
            _ = try await ShellCommand.run(cmd2[0], arguments: Array(cmd2.dropFirst()))
            _ = try await ShellCommand.run(cmd3[0], arguments: Array(cmd3.dropFirst()))
        } else {
            let combined = "\(cmd1.joined(separator: " ")) && \(cmd2.joined(separator: " ")) && \(cmd3.joined(separator: " "))"
            do {
                _ = try await PrivilegeHelper.runElevated(script: combined)
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "clean-proxies", arguments: [service])
            }
        }
        recordEvent("Cleaned auto-proxy PAC and web proxy settings on '\(service)'")
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
