import Foundation

/// Lightweight DHCP lease management service and IP allocator for the hotspot subnet (192.168.2.0/24).
public final class DHCPServer: @unchecked Sendable {

    private let config: HotspotConfiguration
    private var leases: [String: DHCPLease] = [:] // MAC -> Lease
    private var allocatedIPs: Set<String> = []
    private let lock = NSLock()
    private var isRunning: Bool = false

    public init(config: HotspotConfiguration = .default) {
        self.config = config
    }

    /// Handles DHCP DISCOVER: checks for active lease renewal or allocates next available candidate IP.
    public func handleDiscover(mac: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        cleanExpiredLeasesUnderLock()

        if let existing = leases[mac], !existing.isExpired {
            return existing.ipAddress
        }

        // Allocate from range 10...100
        for i in 10...100 {
            let candidate = "192.168.2.\(i)"
            if !allocatedIPs.contains(candidate) {
                return candidate
            }
        }
        return nil // Pool exhausted
    }

    /// Handles DHCP REQUEST: binds IP address to client MAC with a lease record.
    public func handleRequest(
        mac: String,
        requestedIP: String,
        hostname: String? = nil,
        duration: TimeInterval = 86400
    ) -> DHCPLease? {
        lock.lock()
        defer { lock.unlock() }

        if let existing = leases[mac], existing.ipAddress != requestedIP {
            allocatedIPs.remove(existing.ipAddress)
        }
        allocatedIPs.insert(requestedIP)
        let lease = DHCPLease(ipAddress: requestedIP, macAddress: mac, hostname: hostname, leaseStart: Date(), leaseDuration: duration)
        leases[mac] = lease
        return lease
    }

    /// Handles DHCP RELEASE: frees client IP back into the available address pool.
    public func handleRelease(mac: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let lease = leases.removeValue(forKey: mac) else { return false }
        allocatedIPs.remove(lease.ipAddress)
        return true
    }

    /// Convenience allocation combining discovery and request.
    public func allocate(mac: String, hostname: String? = nil, duration: TimeInterval = 3600) -> DHCPLease? {
        lock.lock()
        defer { lock.unlock() }

        cleanExpiredLeasesUnderLock()

        if let existing = leases[mac], !existing.isExpired {
            return existing
        }

        for i in 10...100 {
            let candidate = "192.168.2.\(i)"
            if !allocatedIPs.contains(candidate) {
                allocatedIPs.insert(candidate)
                let lease = DHCPLease(ipAddress: candidate, macAddress: mac, hostname: hostname, leaseStart: Date(), leaseDuration: duration)
                leases[mac] = lease
                return lease
            }
        }
        return nil
    }

    /// Frees lease for specified client MAC.
    public func release(mac: String) {
        _ = handleRelease(mac: mac)
    }

    public var activeLeaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        cleanExpiredLeasesUnderLock()
        return leases.count
    }

    public var allLeases: [DHCPLease] {
        lock.lock()
        defer { lock.unlock() }
        cleanExpiredLeasesUnderLock()
        return Array(leases.values)
    }

    private func cleanExpiredLeasesUnderLock() {
        let now = Date()
        let expired = leases.filter { $0.value.expiresAt < now }
        for (mac, lease) in expired {
            leases.removeValue(forKey: mac)
            allocatedIPs.remove(lease.ipAddress)
        }
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
        leases.removeAll()
        allocatedIPs.removeAll()
    }
}

// MARK: - Aliases for Test Compatibility

public typealias DHCPServerSimulator = DHCPServer
public typealias SimpleDHCPPool = DHCPServer
