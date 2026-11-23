import Foundation

public final class RoutePinningEngine: Sendable {
    public static let campusSubnets: [String] = ["10.8.0.0/16", "10.4.0.0/16"]
    public static let defaultGateway: String = "10.1.36.1"
    public static let defaultInterface: String = "en10"

    public let gateway: String
    public let interface: String

    public init(gateway: String = defaultGateway, interface: String = defaultInterface) {
        self.gateway = gateway
        self.interface = interface
    }

    /// Validates CIDR notation (e.g. "10.8.0.0/16"). Prefix must be 0...32 and 4 octets 0...255.
    public static func validateCIDR(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              prefix >= 0 && prefix <= 32 else { return false }
        let octets = parts[0].split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { Int($0) != nil && Int($0)! >= 0 && Int($0)! <= 255 }
    }

    /// Converts a CIDR prefix length (e.g. 16) to dotted-decimal netmask (e.g. "255.255.0.0").
    public static func cidrToNetmask(prefix: Int) -> String {
        guard prefix >= 0 && prefix <= 32 else { return "255.255.255.255" }
        if prefix == 0 { return "0.0.0.0" }
        let mask: UInt32 = ~0 << (32 - prefix)
        let b1 = (mask >> 24) & 0xFF
        let b2 = (mask >> 16) & 0xFF
        let b3 = (mask >> 8) & 0xFF
        let b4 = mask & 0xFF
        return "\(b1).\(b2).\(b3).\(b4)"
    }

    /// Generates route add command array matching system CLI format.
    public func makeAddRouteCommand(subnet: String, netmask: String = "255.255.0.0") -> [String] {
        ["route", "-n", "add", "-net", subnet, "-netmask", netmask, gateway, "-interface", interface]
    }

    /// Generates route delete command array matching system CLI format.
    public func makeDeleteRouteCommand(subnet: String, netmask: String = "255.255.0.0") -> [String] {
        ["route", "-n", "delete", "-net", subnet, "-netmask", netmask, gateway]
    }

    /// Generates the manual bash command line for unprivileged users.
    public func manualAddCommand(subnet: String, netmask: String? = nil) -> String {
        if let netmask = netmask {
            return "sudo /sbin/route -n add -net \(subnet) -netmask \(netmask) \(gateway) -ifp \(interface)"
        } else {
            return "sudo /sbin/route -n add -net \(subnet) \(gateway) -ifp \(interface)"
        }
    }

    /// Generates manual delete command line.
    public func manualDeleteCommand(subnet: String, netmask: String? = nil) -> String {
        if let netmask = netmask {
            return "sudo /sbin/route -n delete -net \(subnet) -netmask \(netmask) \(gateway)"
        } else {
            return "sudo /sbin/route -n delete -net \(subnet) \(gateway)"
        }
    }

    /// Pins a subnet to the gateway via interface, executing with elevation if possible.
    public func pinSubnet(
        subnet: String,
        gateway: String? = nil,
        interface: String? = nil
    ) async -> RoutePinningResult {
        let gw = gateway ?? self.gateway
        let iface = interface ?? self.interface

        // Validate CIDR format if slash is present
        if subnet.contains("/") && !Self.validateCIDR(subnet) {
            return RoutePinningResult(
                success: false,
                subnet: subnet,
                gateway: gw,
                interface: iface,
                message: "Malformed CIDR subnet notation: \(subnet)",
                manualCommand: nil
            )
        }

        let cmd = "/sbin/route -n add -net \(subnet) \(gw) -ifp \(iface)"
        let fallback = "sudo \(cmd)"

        do {
            let output: ShellOutput
            if PrivilegeHelper.isRoot {
                output = try await ShellCommand.runBash(cmd)
            } else {
                output = try await PrivilegeHelper.runElevated(script: cmd)
            }

            if output.succeeded || output.stderr.contains("File exists") {
                return RoutePinningResult(
                    success: true,
                    subnet: subnet,
                    gateway: gw,
                    interface: iface,
                    message: output.stderr.contains("File exists") ? "Route already pinned in kernel (idempotent)" : "Successfully pinned subnet",
                    manualCommand: nil
                )
            } else {
                return RoutePinningResult(
                    success: false,
                    subnet: subnet,
                    gateway: gw,
                    interface: iface,
                    message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    manualCommand: fallback
                )
            }
        } catch {
            return RoutePinningResult(
                success: false,
                subnet: subnet,
                gateway: gw,
                interface: iface,
                message: error.localizedDescription,
                manualCommand: fallback
            )
        }
    }

    /// Unpins a subnet, executing with elevation if possible.
    public func unpinSubnet(
        subnet: String,
        gateway: String? = nil
    ) async -> RoutePinningResult {
        let gw = gateway ?? self.gateway
        let iface = self.interface
        let cmd = "/sbin/route -n delete -net \(subnet) \(gw)"
        let fallback = "sudo \(cmd)"

        do {
            let output: ShellOutput
            if PrivilegeHelper.isRoot {
                output = try await ShellCommand.runBash(cmd)
            } else {
                output = try await PrivilegeHelper.runElevated(script: cmd)
            }

            if output.succeeded || output.stderr.contains("not in table") {
                return RoutePinningResult(
                    success: true,
                    subnet: subnet,
                    gateway: gw,
                    interface: iface,
                    message: output.stderr.contains("not in table") ? "Route not in table (idempotent)" : "Successfully unpinned subnet",
                    manualCommand: nil
                )
            } else {
                return RoutePinningResult(
                    success: false,
                    subnet: subnet,
                    gateway: gw,
                    interface: iface,
                    message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    manualCommand: fallback
                )
            }
        } catch {
            return RoutePinningResult(
                success: false,
                subnet: subnet,
                gateway: gw,
                interface: iface,
                message: error.localizedDescription,
                manualCommand: fallback
            )
        }
    }

    /// Queries the live IPv4 kernel routing table and parses all active pinned routes.
    public func currentPinnedRoutes() async throws -> [PinnedRoute] {
        let output = try await ShellCommand.run("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        return parseRoutingTable(output: output.stdout)
    }

    /// Parses the text output of `netstat -rn -f inet` into structured PinnedRoute models.
    public func parseRoutingTable(output: String) -> [PinnedRoute] {
        var routes: [PinnedRoute] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.count >= 4 else { continue }

            let destination = tokens[0]
            let gateway = tokens[1]
            let flags = tokens[2]
            let netif = tokens[3]

            // Look for IPv4 network destinations (CIDR notation or IP)
            if destination.contains("/") || destination.contains(".") {
                let isActive = flags.contains("U") // Route is Up
                let netmask: String
                if destination.contains("/") {
                    let parts = destination.split(separator: "/")
                    let prefix = parts.count > 1 ? Int(parts[1]) ?? 32 : 32
                    netmask = Self.cidrToNetmask(prefix: prefix)
                } else {
                    netmask = "255.255.255.255"
                }

                routes.append(PinnedRoute(
                    subnet: destination,
                    netmask: netmask,
                    gateway: gateway,
                    interface: netif,
                    isActive: isActive
                ))
            }
        }
        return routes
    }

    /// Checks whether the target subnet is currently pinned or routed through a conflicting interface.
    public func detectRouteCollision(subnet: String, expectedInterface: String) async throws -> String? {
        let routes = try await currentPinnedRoutes()
        let cleanSubnet = subnet.split(separator: "/").first.map(String.init) ?? subnet

        for route in routes {
            if route.subnet.hasPrefix(cleanSubnet) {
                if route.interface != expectedInterface {
                    return route.interface
                }
            }
        }
        return nil
    }

    /// Checks if a subnet is present in raw routing table output.
    public func isSubnetPinned(subnet: String, inRouteTable output: String) -> Bool {
        let lines = output.components(separatedBy: .newlines)
        return lines.contains { line in
            line.contains(subnet) && line.contains(interface)
        }
    }
}
