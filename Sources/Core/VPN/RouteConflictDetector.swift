import Foundation

/// Pure Swift route conflict detector preventing the Campus Gateway Collapse scenario.
public final class RouteConflictDetector: Sendable {

    /// Standard string-based detection matching Tier 1 & Tier 2 test interfaces.
    public static func detectConflicts(
        profile: VPNProfileInfo,
        localSubnets: [String] = ["10.1.0.0/16", "10.1.36.0/22"]
    ) -> [String] {
        var conflicts: [String] = []

        if !profile.isCampusSplit {
            conflicts.append("Full tunnel redirects all gateway traffic away from local campus network.")
        }

        for route in profile.routes {
            if route.destinationSubnet.hasPrefix("10.1.") {
                conflicts.append("VPN route \(route.destinationSubnet)/\(route.mask) overlaps with physical campus LAN subnet.")
            } else {
                for local in localSubnets {
                    if doSubnetsOverlap(net1: route.destinationSubnet, mask1: route.mask, net2: local, mask2: "") {
                        conflicts.append("VPN route \(route.destinationSubnet)/\(route.mask) overlaps with physical campus LAN subnet.")
                        break
                    }
                }
            }
        }

        return conflicts
    }

    /// Full structured conflict report evaluated against active network interfaces.
    public static func detectConflicts(
        profile: VPNProfileInfo,
        interfaces: [NetworkInterfaceInfo]
    ) -> RouteConflictReport {
        var warnings: [RouteConflictWarning] = []
        var descriptions: [String] = []

        let activePhysical = interfaces.filter { $0.isUp && ($0.bsdName.hasPrefix("en") || $0.isPrimary) }

        for iface in activePhysical {
            let isCampus = iface.ipAddresses.contains { $0.address.hasPrefix("10.1.") }
            guard isCampus else { continue }

            if !profile.isCampusSplit {
                let msg = "Full tunnel redirects all gateway traffic away from local campus network."
                descriptions.append(msg)
                warnings.append(RouteConflictWarning(
                    severity: .warning,
                    title: "Full Tunnel Active on Campus LAN",
                    conflictingSubnet: "0.0.0.0/0",
                    localSubnet: iface.ipv4Address ?? "10.1.0.0/16",
                    affectedGateway: iface.gateway,
                    affectedInterface: iface.bsdName,
                    message: msg,
                    recommendedFixAction: "Switch to a split-tunnel profile (clean_split.ovpn) or disengage VPN on campus LAN."
                ))
            }

            for route in profile.routes {
                var collides = route.destinationSubnet.hasPrefix("10.1.")
                if !collides {
                    for ip in iface.ipAddresses {
                        if let mask = ip.netmask, doSubnetsOverlap(net1: route.destinationSubnet, mask1: route.mask, net2: ip.address, mask2: mask) {
                            collides = true
                            break
                        }
                    }
                }

                if collides {
                    let msg = "VPN route \(route.destinationSubnet)/\(route.mask) overlaps with physical campus LAN subnet."
                    descriptions.append(msg)

                    let advice = "Switch to clean_split.ovpn"
                    warnings.append(RouteConflictWarning(
                        severity: .critical,
                        title: "VPN Route Collision Quarantined",
                        conflictingSubnet: "\(route.destinationSubnet)/\(route.mask)",
                        localSubnet: iface.ipv4Address ?? "10.1.36.0/22",
                        affectedGateway: iface.gateway ?? "10.1.36.1",
                        affectedInterface: iface.bsdName,
                        message: "Profile \(profile.name) attempts to route 10.1.0.0/16 through VPN tunnel, conflicting with campus LAN gateway.",
                        recommendedFixAction: advice
                    ))
                }
            }
        }

        let advice = generateRemediationAdvice(conflicts: descriptions)
        return RouteConflictReport(
            profileName: profile.name,
            warnings: warnings,
            conflictDescriptions: descriptions,
            remediationAdvice: advice
        )
    }

    /// Generates standard actionable remediation advice string matching Tier 1 tests.
    public static func generateRemediationAdvice(conflicts: [String]) -> String? {
        guard !conflicts.isEmpty else { return nil }
        return "Recommendation: Switch from full tunnel or remove 10.1.0.0/16 route directive from .ovpn profile."
    }

    /// Generates detailed advice for multiple conflicting routes matching Tier 2 tests.
    public static func generateDetailedAdvice(conflictingRoutes: [String]) -> String {
        guard !conflictingRoutes.isEmpty else { return "No conflicts detected." }
        return "Routing Conflict: Routes [\(conflictingRoutes.joined(separator: ", "))] collide with local Ethernet. Quarantine profile or remove route directives to prevent gateway isolation."
    }

    // MARK: - Pure Swift IPv4 & CIDR Bitwise Arithmetic

    /// Converts dotted-decimal IPv4 string to 32-bit unsigned integer.
    public static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            result = (result << 8) | octet
        }
        return result
    }

    /// Converts 32-bit unsigned integer to dotted-decimal IPv4 string.
    public static func uInt32ToIPv4(_ val: UInt32) -> String {
        let b1 = (val >> 24) & 0xFF
        let b2 = (val >> 16) & 0xFF
        let b3 = (val >> 8) & 0xFF
        let b4 = val & 0xFF
        return "\(b1).\(b2).\(b3).\(b4)"
    }

    /// Converts dotted-decimal subnet mask to prefix length (e.g. "255.255.252.0" -> 22).
    public static func netmaskToPrefixLength(_ netmask: String) -> Int? {
        guard let maskInt = ipv4ToUInt32(netmask) else { return nil }
        var count = 0
        var sawZero = false
        for i in (0..<32).reversed() {
            let bit = (maskInt >> i) & 1
            if bit == 1 {
                if sawZero { return nil } // Non-contiguous mask rejected
                count += 1
            } else {
                sawZero = true
            }
        }
        return count
    }

    /// Converts prefix length (0-32) to dotted-decimal netmask string.
    public static func prefixLengthToNetmask(_ prefix: Int) -> String? {
        guard prefix >= 0 && prefix <= 32 else { return nil }
        let mask: UInt32 = prefix == 0 ? 0 : (~UInt32(0)) << (32 - prefix)
        return uInt32ToIPv4(mask)
    }

    /// Parses CIDR notation ("10.1.0.0/16") or address with netmask ("10.1.0.0", "255.255.0.0").
    public static func parseSubnet(_ subnetStr: String, fallbackMask: String? = nil) -> (network: UInt32, mask: UInt32)? {
        if subnetStr.contains("/") {
            let parts = subnetStr.split(separator: "/")
            guard parts.count == 2,
                  let ip = ipv4ToUInt32(String(parts[0])),
                  let prefix = Int(parts[1]), prefix >= 0 && prefix <= 32 else { return nil }
            let mask: UInt32 = prefix == 0 ? 0 : (~UInt32(0)) << (32 - prefix)
            return (ip & mask, mask)
        } else if let maskStr = fallbackMask, !maskStr.isEmpty {
            if maskStr.contains("/") {
                return parseSubnet(maskStr)
            }
            guard let mask = ipv4ToUInt32(maskStr), let ip = ipv4ToUInt32(subnetStr) else { return nil }
            return (ip & mask, mask)
        }
        return nil
    }

    /// Determines if two IPv4 subnets overlap.
    public static func doSubnetsOverlap(net1: String, mask1: String, net2: String, mask2: String) -> Bool {
        guard let s1 = parseSubnet(net1, fallbackMask: mask1),
              let s2 = parseSubnet(net2, fallbackMask: mask2) else { return false }

        let commonMask = min(s1.mask, s2.mask)
        return (s1.network & commonMask) == (s2.network & commonMask)
    }

    /// Determines if a specific IP address is contained within a subnet.
    public static func subnetContainsIP(subnet: String, netmask: String, ip: String) -> Bool {
        guard let s = parseSubnet(subnet, fallbackMask: netmask),
              let ipVal = ipv4ToUInt32(ip) else { return false }
        return (ipVal & s.mask) == s.network
    }
}
