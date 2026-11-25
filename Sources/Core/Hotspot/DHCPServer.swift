import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Errors thrown by the DHCPServer UDP socket listener.
public enum DHCPServerError: Error, LocalizedError, Sendable, Equatable {
    case socketCreationFailed(errno: Int32, message: String)
    case bindFailed(port: UInt16, errno: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let code, let msg):
            return "Failed to create DHCP UDP socket (errno \(code)): \(msg)"
        case .bindFailed(let port, let code, let msg):
            return "Failed to bind DHCP UDP socket on port \(port) (errno \(code)): \(msg)"
        }
    }
}

/// Lightweight DHCP lease management service and IP allocator for the hotspot subnet (192.168.2.0/24).
public final class DHCPServer: @unchecked Sendable {

    private struct Reservation {
        let ipAddress: String
        let expiresAt: Date
    }

    private let config: HotspotConfiguration
    private var leases: [String: DHCPLease] = [:] // MAC -> Lease
    private var allocatedIPs: Set<String> = []
    private var reservations: [String: Reservation] = [:] // MAC -> Reservation
    private let lock = NSLock()
    private var isRunning: Bool = false

    private let udpQueue = DispatchQueue(label: "com.netboost.dhcpserver.udp", qos: .userInitiated)
    private let udpQueueKey = DispatchSpecificKey<UInt8>()
    private var udpSocketFD: Int32 = -1
    private var udpReadSource: DispatchSourceRead?
    private var udpCancelGroup: DispatchGroup?
    private var _listeningPort: UInt16?

    public var listeningPort: UInt16? {
        lock.withLock { _listeningPort }
    }

    public init(config: HotspotConfiguration = .default) {
        self.config = config
        self.udpQueue.setSpecific(key: udpQueueKey, value: 1)
    }

    deinit {
        stopUDPListener()
    }

    private var subnetPrefix: String {
        let parts = config.gateway.split(separator: ".")
        if parts.count == 4 {
            return "\(parts[0]).\(parts[1]).\(parts[2])."
        }
        return "192.168.2."
    }

    // MARK: - macOS bootpd Lease File Parser

    /// Parses macOS `bootpd` lease database contents (typically `/var/db/dhcpd_leases`).
    public static func parseBootpdLeases(contents: String) -> [DHCPLease] {
        var parsed: [DHCPLease] = []
        var currentFields: [String: String] = [:]
        var insideBlock = false

        func finalizeBlock() {
            guard let ip = currentFields["ip_address"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ip.isEmpty,
                  let rawHW = currentFields["hw_address"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawHW.isEmpty else {
                currentFields.removeAll()
                return
            }

            // bootpd formats hw_address as "<htype>,<mac>", e.g. "1,66:61:c9:cc:5b:91"
            let macComponent: String
            if let commaIdx = rawHW.firstIndex(of: ",") {
                macComponent = String(rawHW[rawHW.index(after: commaIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                macComponent = rawHW
            }
            guard !macComponent.isEmpty else {
                currentFields.removeAll()
                return
            }

            let rawName = currentFields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hostname = (rawName?.isEmpty == false) ? rawName : nil

            let defaultDuration: TimeInterval = 86400
            var leaseStart = Date()
            if let rawLease = currentFields["lease"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawLease.isEmpty {
                let epochSeconds: TimeInterval?
                if rawLease.lowercased().hasPrefix("0x"),
                   let hexVal = UInt64(rawLease.dropFirst(2), radix: 16) {
                    epochSeconds = TimeInterval(hexVal)
                } else if let decVal = TimeInterval(rawLease) {
                    epochSeconds = decVal
                } else {
                    epochSeconds = nil
                }
                if let expEpoch = epochSeconds {
                    let expiresAt = Date(timeIntervalSince1970: expEpoch)
                    leaseStart = expiresAt.addingTimeInterval(-defaultDuration)
                }
            }

            parsed.append(DHCPLease(
                ipAddress: ip,
                macAddress: macComponent.lowercased(),
                hostname: hostname,
                leaseStart: leaseStart,
                leaseDuration: defaultDuration
            ))
            currentFields.removeAll()
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "{" {
                currentFields.removeAll()
                insideBlock = true
                continue
            }
            if line == "}" {
                if insideBlock {
                    finalizeBlock()
                }
                insideBlock = false
                continue
            }
            if insideBlock, let eqIdx = line.firstIndex(of: "=") {
                let key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                let val = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                currentFields[key] = val
            }
        }

        return parsed
    }

    /// Reads and parses `/var/db/dhcpd_leases` (or an alternate path) from disk.
    public static func parseBootpdLeases(at path: String = "/var/db/dhcpd_leases") -> [DHCPLease] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return parseBootpdLeases(contents: contents)
    }

    // MARK: - Synchronous Lease Allocator

    /// Handles DHCP DISCOVER: checks for active lease renewal or allocates next available candidate IP with a 60-second reservation.
    public func handleDiscover(mac: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        cleanExpiredLeasesUnderLock()

        if let existing = leases[mac], !existing.isExpired {
            return existing.ipAddress
        }

        if let existingReservation = reservations[mac], existingReservation.expiresAt > Date() {
            return existingReservation.ipAddress
        }

        let reservedIPs = Set(reservations.values.map { $0.ipAddress })
        let prefix = subnetPrefix

        // Allocate from range 10...100
        for i in 10...100 {
            let candidate = "\(prefix)\(i)"
            if !allocatedIPs.contains(candidate) && !reservedIPs.contains(candidate) {
                // Hold reservation for 60 seconds to prevent concurrent DISCOVER duplicate offers
                reservations[mac] = Reservation(ipAddress: candidate, expiresAt: Date().addingTimeInterval(60))
                return candidate
            }
        }
        return nil // Pool exhausted
    }

    /// Handles DHCP REQUEST: binds IP address to client MAC with a lease record, rejecting collisions with active leases or other reservations.
    public func handleRequest(
        mac: String,
        requestedIP: String,
        hostname: String? = nil,
        duration: TimeInterval = 86400
    ) -> DHCPLease? {
        lock.lock()
        defer { lock.unlock() }

        cleanExpiredLeasesUnderLock()

        // Verify that requestedIP is not already leased to a different active client MAC
        if leases.contains(where: { $0.value.ipAddress == requestedIP && $0.key != mac && !$0.value.isExpired }) {
            return nil // IP collision detected
        }

        // Verify that requestedIP is not reserved by a different client MAC
        if reservations.contains(where: { $0.value.ipAddress == requestedIP && $0.key != mac && $0.value.expiresAt > Date() }) {
            return nil // IP reserved by another client
        }

        reservations.removeValue(forKey: mac)

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

        reservations.removeValue(forKey: mac)
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

        reservations.removeValue(forKey: mac)
        let reservedIPs = Set(reservations.values.map { $0.ipAddress })
        let prefix = subnetPrefix

        for i in 10...100 {
            let candidate = "\(prefix)\(i)"
            if !allocatedIPs.contains(candidate) && !reservedIPs.contains(candidate) {
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
        reservations = reservations.filter { $0.value.expiresAt > now }
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = true
    }

    public func stop() {
        stopUDPListener()
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
        leases.removeAll()
        allocatedIPs.removeAll()
        reservations.removeAll()
    }

    // MARK: - Non-Blocking Darwin UDP Listener (RFC 2131)

    /// Starts a non-blocking Darwin `SOCK_DGRAM` UDP listener on the specified port (default 67) on a background queue.
    public func startUDPListener(port: UInt16 = 67) throws {
        stopUDPListener()

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            let code = errno
            throw DHCPServerError.socketCreationFailed(errno: code, message: String(cString: strerror(code)))
        }

        var reuse: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var broadcast: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        let currentFlags = Darwin.fcntl(fd, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw DHCPServerError.bindFailed(port: port, errno: code, message: String(cString: strerror(code)))
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actualPort = port
        if withUnsafeMutablePointer(to: &boundAddr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.getsockname(fd, sa, &boundLen)
            }
        }) == 0 {
            actualPort = UInt16(bigEndian: boundAddr.sin_port)
        }

        let cancelGroup = DispatchGroup()
        cancelGroup.enter()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: udpQueue)
        source.setEventHandler { [weak self] in
            self?.drainIncomingPackets(on: fd)
        }
        source.setCancelHandler {
            Darwin.close(fd)
            cancelGroup.leave()
        }

        lock.withLock {
            self.udpSocketFD = fd
            self.udpReadSource = source
            self.udpCancelGroup = cancelGroup
            self._listeningPort = actualPort
            self.isRunning = true
        }

        source.resume()
    }

    /// Stops the non-blocking UDP listener and closes its socket cleanly.
    public func stopUDPListener() {
        let (existingSource, cancelGroup) = lock.withLock { () -> (DispatchSourceRead?, DispatchGroup?) in
            let src = udpReadSource
            let grp = udpCancelGroup
            udpReadSource = nil
            udpCancelGroup = nil
            udpSocketFD = -1
            _listeningPort = nil
            return (src, grp)
        }

        guard let source = existingSource else { return }
        source.cancel()

        if DispatchQueue.getSpecific(key: udpQueueKey) != 1, let cancelGroup {
            _ = cancelGroup.wait(timeout: .now() + 1.0)
        }
    }

    private func drainIncomingPackets(on fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var fromAddr = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bytesRead = withUnsafeMutablePointer(to: &fromAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.recvfrom(fd, &buffer, buffer.count, 0, sa, &fromLen)
                }
            }
            if bytesRead <= 0 {
                break
            }

            let packetData = Data(buffer[0..<bytesRead])
            guard let replyData = processDHCPPacket(packetData) else { continue }

            let flags = (UInt16(packetData[10]) << 8) | UInt16(packetData[11])
            let activePort = listeningPort ?? 67
            var destAddr = fromAddr
            let isLoopback = (UInt32(bigEndian: fromAddr.sin_addr.s_addr) >> 24) == 127
            if activePort == 67 && !isLoopback && ((flags & 0x8000) != 0 || fromAddr.sin_addr.s_addr == 0) {
                destAddr.sin_addr = in_addr(s_addr: INADDR_BROADCAST.bigEndian)
                destAddr.sin_port = UInt16(68).bigEndian
            }

            _ = replyData.withUnsafeBytes { rawBuf in
                withUnsafePointer(to: &destAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.sendto(fd, rawBuf.baseAddress, replyData.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    /// Parses a raw BOOTP/DHCP wire packet (DISCOVER/REQUEST/RELEASE), delegates to the lease engine, and returns an OFFER/ACK/NAK frame when applicable.
    public func processDHCPPacket(_ packetData: Data) -> Data? {
        let bytes = [UInt8](packetData)
        // BOOTP header (236 bytes) + 4-byte DHCP magic cookie (99, 130, 83, 99)
        guard bytes.count >= 240,
              bytes[0] == 1, // BOOTREQUEST
              bytes[236] == 0x63, bytes[237] == 0x82, bytes[238] == 0x53, bytes[239] == 0x63 else {
            return nil
        }

        let hlen = Int(bytes[2])
        guard hlen == 6 else { return nil }
        let mac = (28..<34).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")

        let ciaddrIP = Self.ipv4String(from: Array(bytes[12..<16]))
        var messageType: UInt8?
        var requestedIP: String?
        var hostname: String?

        var offset = 240
        while offset < bytes.count {
            let code = bytes[offset]
            if code == 0 {
                offset += 1
                continue
            }
            if code == 255 {
                break
            }
            guard offset + 1 < bytes.count else { break }
            let len = Int(bytes[offset + 1])
            let valStart = offset + 2
            guard valStart + len <= bytes.count else { break }
            let val = Array(bytes[valStart..<(valStart + len)])

            switch code {
            case 53 where len >= 1:
                messageType = val[0]
            case 50 where len == 4:
                requestedIP = Self.ipv4String(from: val)
            case 12 where len > 0:
                hostname = String(bytes: val, encoding: .utf8)
            default:
                break
            }
            offset = valStart + len
        }

        guard let msgType = messageType else { return nil }

        switch msgType {
        case 1: // DHCPDISCOVER -> DHCPOFFER (2)
            guard let offeredIP = handleDiscover(mac: mac) else { return nil }
            return buildDHCPReply(requestBytes: bytes, replyType: 2, assignedIP: offeredIP, leaseSeconds: 86400)

        case 3: // DHCPREQUEST -> DHCPACK (5) or DHCPNAK (6)
            let targetIP = requestedIP ?? (ciaddrIP == "0.0.0.0" ? nil : ciaddrIP)
            guard let reqIP = targetIP,
                  let lease = handleRequest(mac: mac, requestedIP: reqIP, hostname: hostname) else {
                return buildDHCPReply(requestBytes: bytes, replyType: 6, assignedIP: "0.0.0.0", leaseSeconds: 0)
            }
            return buildDHCPReply(
                requestBytes: bytes,
                replyType: 5,
                assignedIP: lease.ipAddress,
                leaseSeconds: UInt32(max(60, Int(lease.leaseDuration)))
            )

        case 7: // DHCPRELEASE
            _ = handleRelease(mac: mac)
            return nil

        default:
            return nil
        }
    }

    private func buildDHCPReply(
        requestBytes: [UInt8],
        replyType: UInt8,
        assignedIP: String,
        leaseSeconds: UInt32
    ) -> Data {
        var reply = [UInt8](repeating: 0, count: 240)
        reply[0] = 2 // BOOTREPLY
        reply[1] = requestBytes[1]
        reply[2] = requestBytes[2]
        reply[3] = 0
        for i in 4..<12 { reply[i] = requestBytes[i] }
        let yiaddrBytes = Self.ipv4Bytes(from: assignedIP) ?? [0, 0, 0, 0]
        for i in 0..<4 { reply[16 + i] = yiaddrBytes[i] }
        let serverBytes = Self.ipv4Bytes(from: config.gateway) ?? [192, 168, 2, 1]
        for i in 0..<4 { reply[20 + i] = serverBytes[i] }
        for i in 24..<44 { reply[i] = requestBytes[i] }
        reply[236] = 0x63
        reply[237] = 0x82
        reply[238] = 0x53
        reply[239] = 0x63

        reply.append(contentsOf: [53, 1, replyType])
        reply.append(contentsOf: [54, 4])
        reply.append(contentsOf: serverBytes)

        if replyType != 6 { // Not NAK
            reply.append(contentsOf: [
                51, 4,
                UInt8((leaseSeconds >> 24) & 0xFF),
                UInt8((leaseSeconds >> 16) & 0xFF),
                UInt8((leaseSeconds >> 8) & 0xFF),
                UInt8(leaseSeconds & 0xFF)
            ])
            reply.append(contentsOf: [1, 4, 255, 255, 255, 0])
            reply.append(contentsOf: [3, 4])
            reply.append(contentsOf: serverBytes)
            reply.append(contentsOf: [6, 4])
            reply.append(contentsOf: serverBytes)
        }

        reply.append(255)
        return Data(reply)
    }

    private static func ipv4String(from bytes: [UInt8]) -> String {
        guard bytes.count == 4 else { return "0.0.0.0" }
        return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
    }

    private static func ipv4Bytes(from ip: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        let raw = UInt32(bigEndian: addr.s_addr)
        return [
            UInt8((raw >> 24) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8(raw & 0xFF)
        ]
    }
}

// MARK: - Aliases for Test Compatibility

public typealias DHCPServerSimulator = DHCPServer
public typealias SimpleDHCPPool = DHCPServer
