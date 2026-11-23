import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Discovers connected hotspot devices via kernel ARP table inspection and tracks throughput metrics.
public final class ARPScanner: @unchecked Sendable {

    private var clientThroughputStats: [String: (tx: UInt64, rx: UInt64)] = [:]
    private let lock = NSLock()

    public init() {}

    /// Performs reverse DNS lookup for an IP address via getnameinfo.
    public static func reverseDNS(ipAddress: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_flags = AI_NUMERICHOST
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ipAddress, nil, &hints, &res) == 0, let info = res else {
            return nil
        }
        defer { freeaddrinfo(res) }

        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            info.pointee.ai_addr,
            info.pointee.ai_addrlen,
            &hostBuf,
            socklen_t(hostBuf.count),
            nil,
            0,
            NI_NAMEREQD
        )
        guard status == 0 else { return nil }
        let name = hostBuf.withUnsafeBufferPointer { ptr in String(cString: ptr.baseAddress!) }
        return name.isEmpty ? nil : name
    }

    /// Parses output from `arp -an` or `arp -a`, filtering for the hotspot subnet (192.168.2.0/24).
    public static func parseHotspotClients(
        arpOutput: String,
        leases: [DHCPLease] = [],
        subnetPrefix: String = "192.168.2."
    ) -> [HotspotClient] {
        var clients: [HotspotClient] = []
        let lines = arpOutput.components(separatedBy: .newlines)

        for line in lines {
            // e.g. "? (192.168.2.15) at a4:83:e7:22:11:00 on en0 ifscope [ethernet]"
            guard line.contains(subnetPrefix) else { continue }

            if let startParen = line.firstIndex(of: "("),
               let endParen = line.firstIndex(of: ")"),
               let atRange = line.range(of: " at ") {
                let ip = String(line[line.index(after: startParen)..<endParen])

                // Skip hotspot gateway itself
                if ip == "192.168.2.1" { continue }

                let remainder = line[atRange.upperBound...]
                let mac = String(remainder.split(separator: " ").first ?? "")

                let lease = leases.first {
                    $0.ipAddress == ip || $0.macAddress.lowercased() == mac.lowercased()
                }
                // Check lease hostname first, fallback to genuine reverse DNS lookup, or nil
                let hostname = lease?.hostname ?? reverseDNS(ipAddress: ip)

                clients.append(HotspotClient(
                    macAddress: mac,
                    ipAddress: ip,
                    hostname: hostname,
                    txBytes: 0,
                    rxBytes: 0
                ))
            }
        }
        return clients
    }

    private func mergeStats(for clients: inout [HotspotClient]) {
        lock.withLock {
            for i in 0..<clients.count {
                let mac = clients[i].macAddress
                if let existing = clientThroughputStats[mac] {
                    clients[i].txBytes = existing.tx
                    clients[i].rxBytes = existing.rx
                } else {
                    clientThroughputStats[mac] = (clients[i].txBytes, clients[i].rxBytes)
                }
            }
        }
    }

    /// Queries live system ARP table via `/usr/sbin/arp -an` and parses active hotspot clients.
    public func scan(
        subnetPrefix: String = "192.168.2.",
        leases: [DHCPLease] = []
    ) async throws -> [HotspotClient] {
        let output = try await ShellCommand.run("/usr/sbin/arp", arguments: ["-an"])
        guard output.succeeded else { return [] }

        var clients = Self.parseHotspotClients(arpOutput: output.stdout, leases: leases, subnetPrefix: subnetPrefix)
        mergeStats(for: &clients)
        return clients
    }

    /// Updates byte counters for a connected client MAC.
    public func recordTraffic(mac: String, txDelta: UInt64, rxDelta: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        var current = clientThroughputStats[mac] ?? (0, 0)
        current.tx += txDelta
        current.rx += rxDelta
        clientThroughputStats[mac] = current
    }

    /// Retrieves current recorded throughput for a client MAC.
    public func throughput(for mac: String) -> (tx: UInt64, rx: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return clientThroughputStats[mac] ?? (0, 0)
    }
}

// MARK: - Aliases for Test Compatibility

public typealias ARPClientScanner = ARPScanner
