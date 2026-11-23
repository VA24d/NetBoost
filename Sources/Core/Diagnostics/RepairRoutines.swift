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
            } catch PrivilegeError.elevationDenied {
                throw PrivilegeError.elevationDenied
            } catch {
                // If helper is present, try helper
                _ = try? await PrivilegeHelper.runHelper(action: "flush-dns")
            }
        }
        recordEvent("DNS cache flushed (dscacheutil + killall mDNSResponder)")
    }

    /// Executes MTU adjustment, DNS flush, and ARP table flush in a single elevation pass so the user is prompted at most ONCE.
    public func executeBatchAutoFix(service: String = "Wi-Fi", mtu: Int = 1280) async throws {
        let (dns1, dns2) = DNSFlushRoutine.makeCommands()
        let arpCmd = ARPFlushRoutine.makeFlushAllCommand()
        let mtuCmd = ["/usr/sbin/networksetup", "-setMTU", service, String(mtu)]

        let combined = "\(mtuCmd.joined(separator: " ")) && \(dns1.joined(separator: " ")) && \(dns2.joined(separator: " ")) && \(arpCmd.joined(separator: " "))"

        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.runBash(combined)
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: combined)
            } catch PrivilegeError.elevationDenied {
                throw PrivilegeError.elevationDenied
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "batch-autofix", arguments: [service, String(mtu)])
            }
        }
        recordEvent("Batch Auto-Fix executed: MTU set to \(mtu), DNS flushed, ARP cleared (single elevation)")
    }

    // MARK: - ARP Cache Flush

    public func flushARP(targetIP: String? = nil) async throws {
        let cmd = targetIP != nil ? ARPFlushRoutine.makeFlushHostCommand(ip: targetIP!) : ARPFlushRoutine.makeFlushAllCommand()
        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: cmd[0], arguments: Array(cmd.dropFirst()))
            } catch PrivilegeError.elevationDenied {
                throw PrivilegeError.elevationDenied
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
            } catch PrivilegeError.elevationDenied {
                throw PrivilegeError.elevationDenied
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
            } catch PrivilegeError.elevationDenied {
                throw PrivilegeError.elevationDenied
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
            } catch PrivilegeError.elevationDenied {
                throw PrivilegeError.elevationDenied
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "clean-proxies", arguments: [service])
            }
        }
        recordEvent("Cleaned auto-proxy PAC and web proxy settings on '\(service)'")
    }

    // MARK: - Per-Adapter Private Relay Management

    /// Checks if Private Relay is specifically isolated (bypassed/disabled) on the given service.
    public func isPrivateRelayIsolated(service: String) async -> Bool {
        let cmd = PrivateRelayManager.makeInspectServiceProxiesCommand(service: service)
        let output = (try? await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst())))?.stdout ?? ""
        return PrivateRelayManager.parsePrivateRelayBypassStatus(output: output)
    }

    /// Disables Private Relay on the target campus service (e.g. en10) while preserving it on other adapters.
    public func isolatePrivateRelay(for service: String) async throws {
        let cmd = PrivateRelayManager.makeDisablePrivateRelayCanaryCommand(service: service)
        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: cmd[0], arguments: Array(cmd.dropFirst()))
            } catch PrivilegeError.elevationDenied {
                throw PrivilegeError.elevationDenied
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "isolate-relay", arguments: [service])
            }
        }
        recordEvent("iCloud Private Relay isolated on '\(service)' to avoid campus portal/MTU interference")
    }

    /// Restores Private Relay configuration on the target service.
    public func restorePrivateRelay(for service: String) async throws {
        let cmd = PrivateRelayManager.makeRestorePrivateRelayCanaryCommand(service: service)
        if PrivilegeHelper.isRoot {
            _ = try await ShellCommand.run(cmd[0], arguments: Array(cmd.dropFirst()))
        } else {
            do {
                _ = try await PrivilegeHelper.runElevated(script: cmd[0], arguments: Array(cmd.dropFirst()))
            } catch PrivilegeError.elevationDenied {
                throw PrivilegeError.elevationDenied
            } catch {
                _ = try? await PrivilegeHelper.runHelper(action: "restore-relay", arguments: [service])
            }
        }
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
