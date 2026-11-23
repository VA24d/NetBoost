import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Protocol for genuine or mock DNS query resolution.
public protocol DNSResolverProtocol: Sendable {
    func resolve(domain: String, queryType: String, upstreamResolvers: [String]) -> String?
}

/// Standard Darwin BSD socket resolver using UDP queries and getaddrinfo.
public final class DarwinDNSResolver: DNSResolverProtocol, @unchecked Sendable {
    public init() {}

    public func resolve(domain: String, queryType: String, upstreamResolvers: [String]) -> String? {
        // If domain is already a literal IP address, return it directly
        var sa4 = sockaddr_in()
        if inet_pton(AF_INET, domain, &sa4.sin_addr) == 1 {
            return domain
        }
        var sa6 = sockaddr_in6()
        if inet_pton(AF_INET6, domain, &sa6.sin6_addr) == 1 {
            return domain
        }

        // 1. Fast path: standard Darwin BSD getaddrinfo
        if let ip = queryGetAddrInfo(domain: domain, queryType: queryType) {
            return ip
        }

        // 2. Fallback to direct UDP query to upstreamResolvers
        for serverIP in upstreamResolvers {
            if let ip = queryUDP(domain: domain, queryType: queryType, serverIP: serverIP) {
                return ip
            }
        }

        return nil
    }

    private func queryUDP(domain: String, queryType: String, serverIP: String) -> String? {
        var serverAddr = sockaddr_in()
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, serverIP, &serverAddr.sin_addr) == 1 else {
            return nil
        }

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var tv = timeval(tv_sec: 0, tv_usec: 200_000) // 200ms timeout
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let queryID = UInt16.random(in: 1..<UInt16.max)
        var packet = [UInt8]()
        // Header (12 bytes)
        packet.append(UInt8(queryID >> 8))
        packet.append(UInt8(queryID & 0xFF))
        packet.append(0x01) // Flags: standard query, RD=1
        packet.append(0x00)
        packet.append(0x00) // QDCOUNT = 1
        packet.append(0x01)
        packet.append(0x00) // ANCOUNT = 0
        packet.append(0x00)
        packet.append(0x00) // NSCOUNT = 0
        packet.append(0x00)
        packet.append(0x00) // ARCOUNT = 0
        packet.append(0x00)

        // Labels
        let parts = domain.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard let ascii = part.data(using: .ascii), ascii.count <= 63 else { return nil }
            packet.append(UInt8(ascii.count))
            packet.append(contentsOf: ascii)
        }
        packet.append(0x00) // Terminating null

        // QTYPE
        let qType: UInt16 = (queryType.uppercased() == "AAAA") ? 28 : 1
        packet.append(UInt8(qType >> 8))
        packet.append(UInt8(qType & 0xFF))
        // QCLASS: 1 = IN
        packet.append(0x00)
        packet.append(0x01)

        let sent = packet.withUnsafeBytes { ptr in
            withUnsafePointer(to: &serverAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, ptr.baseAddress, ptr.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return nil }

        var responseBuffer = [UInt8](repeating: 0, count: 1024)
        var fromAddr = sockaddr_storage()
        var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let received = withUnsafeMutablePointer(to: &fromAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(sock, &responseBuffer, responseBuffer.count, 0, sa, &fromLen)
            }
        }
        guard received > 12 else { return nil }

        let respID = (UInt16(responseBuffer[0]) << 8) | UInt16(responseBuffer[1])
        guard respID == queryID else { return nil }

        let flags = (UInt16(responseBuffer[2]) << 8) | UInt16(responseBuffer[3])
        guard (flags & 0x8000) != 0, (flags & 0x000F) == 0 else { return nil }

        let anCount = (Int(responseBuffer[6]) << 8) | Int(responseBuffer[7])
        guard anCount > 0 else { return nil }

        // Skip question section
        var offset = 12
        while offset < received && responseBuffer[offset] != 0 {
            let len = Int(responseBuffer[offset])
            if (len & 0xC0) == 0xC0 {
                offset += 2
                break
            } else {
                offset += 1 + len
            }
        }
        if offset < received && responseBuffer[offset] == 0 {
            offset += 1
        }
        offset += 4 // QTYPE + QCLASS
        guard offset <= received else { return nil }

        // Answers
        for _ in 0..<anCount {
            guard offset < received else { break }
            if (responseBuffer[offset] & 0xC0) == 0xC0 {
                offset += 2
            } else {
                while offset < received && responseBuffer[offset] != 0 {
                    let len = Int(responseBuffer[offset])
                    if (len & 0xC0) == 0xC0 {
                        offset += 2
                        break
                    }
                    offset += 1 + len
                }
                if offset < received && responseBuffer[offset] == 0 {
                    offset += 1
                }
            }
            guard offset + 10 <= received else { break }
            let rType = (UInt16(responseBuffer[offset]) << 8) | UInt16(responseBuffer[offset + 1])
            let rdLen = (Int(responseBuffer[offset + 8]) << 8) | Int(responseBuffer[offset + 9])
            offset += 10
            guard offset + rdLen <= received else { break }

            if rType == 1 && rdLen == 4 { // IPv4 A
                var addr = in_addr()
                responseBuffer.withUnsafeBytes { rawBuffer in
                    if let base = rawBuffer.baseAddress {
                        memcpy(&addr, base.advanced(by: offset), 4)
                    }
                }
                var strBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &strBuf, socklen_t(strBuf.count)) != nil {
                    return strBuf.withUnsafeBufferPointer { ptr in String(cString: ptr.baseAddress!) }
                }
            } else if rType == 28 && rdLen == 16 { // IPv6 AAAA
                var addr6 = in6_addr()
                responseBuffer.withUnsafeBytes { rawBuffer in
                    if let base = rawBuffer.baseAddress {
                        memcpy(&addr6, base.advanced(by: offset), 16)
                    }
                }
                var strBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &addr6, &strBuf, socklen_t(strBuf.count)) != nil {
                    return strBuf.withUnsafeBufferPointer { ptr in String(cString: ptr.baseAddress!) }
                }
            }
            offset += rdLen
        }
        return nil
    }

    private func queryGetAddrInfo(domain: String, queryType: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = (queryType.uppercased() == "AAAA") ? AF_INET6 : AF_INET
        hints.ai_socktype = SOCK_STREAM

        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(domain, nil, &hints, &res) == 0, let info = res else {
            return nil
        }
        defer { freeaddrinfo(res) }

        var curr: UnsafeMutablePointer<addrinfo>? = info
        while let ptr = curr {
            if ptr.pointee.ai_family == AF_INET {
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let sa = ptr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var addr = sa.sin_addr
                if inet_ntop(AF_INET, &addr, &ipBuf, socklen_t(ipBuf.count)) != nil {
                    return ipBuf.withUnsafeBufferPointer { ptr in String(cString: ptr.baseAddress!) }
                }
            } else if ptr.pointee.ai_family == AF_INET6 {
                var ipBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let sa = ptr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var addr = sa.sin6_addr
                if inet_ntop(AF_INET6, &addr, &ipBuf, socklen_t(ipBuf.count)) != nil {
                    return ipBuf.withUnsafeBufferPointer { ptr in String(cString: ptr.baseAddress!) }
                }
            }
            curr = ptr.pointee.ai_next
        }
        return nil
    }
}

/// Represents a client DNS domain lookup query.
public struct DNSQuery: Equatable, Sendable {
    public let domain: String
    public let queryType: String // e.g. "A", "AAAA"

    public init(domain: String, queryType: String = "A") {
        self.domain = domain
        self.queryType = queryType
    }
}

/// Represents a resolved DNS answer payload.
public struct DNSResponse: Equatable, Sendable {
    public let domain: String
    public let resolvedIP: String
    public let ttl: Int

    public init(domain: String, resolvedIP: String, ttl: Int = 300) {
        self.domain = domain
        self.resolvedIP = resolvedIP
        self.ttl = ttl
    }
}

/// Local DNS proxy forwarding DNS queries from hotspot clients to campus DNS resolvers (10.4.20.21, 10.4.20.222).
public final class DNSProxy: @unchecked Sendable {

    public static let defaultUpstreamResolvers = ["10.4.20.21", "10.4.20.222", "1.1.1.1"]

    private var cache: [String: (response: DNSResponse, expiresAt: Date)] = [:]
    private let upstreamResolvers: [String]
    private let resolver: DNSResolverProtocol
    public private(set) var isRunning: Bool = false
    private let lock = NSLock()

    // Rate limiting tracking
    private var queryTimestamps: [Date] = []
    public let maxQueriesPerSecond: Int = 100

    public init(
        upstreamResolvers: [String] = defaultUpstreamResolvers,
        resolver: DNSResolverProtocol? = nil
    ) {
        self.upstreamResolvers = upstreamResolvers
        self.resolver = resolver ?? DarwinDNSResolver()
    }

    public convenience init(
        upstreamResolver: String,
        resolver: DNSResolverProtocol? = nil
    ) {
        self.init(upstreamResolvers: [upstreamResolver, "10.4.20.222", "1.1.1.1"], resolver: resolver)
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
        cache.removeAll()
        queryTimestamps.removeAll()
    }

    /// Resolves DNS query with caching, genuine upstream resolution, and rate-limiting.
    public func resolve(query: DNSQuery) -> DNSResponse {
        lock.lock()
        defer { lock.unlock() }

        // 1. Check rate limit
        guard allowQueryUnderLock() else {
            // Drop or return SERVFAIL placeholder
            return DNSResponse(domain: query.domain, resolvedIP: "", ttl: 0)
        }

        // 2. Cache lookup
        if let cached = cache[query.domain], Date() < cached.expiresAt {
            return cached.response
        }

        // 3. Resolve using genuine DNS resolver
        guard let resolvedIP = resolver.resolve(
            domain: query.domain,
            queryType: query.queryType,
            upstreamResolvers: upstreamResolvers
        ), !resolvedIP.isEmpty else {
            return DNSResponse(domain: query.domain, resolvedIP: "", ttl: 0)
        }

        let response = DNSResponse(domain: query.domain, resolvedIP: resolvedIP, ttl: 300)
        cache[query.domain] = (response, Date().addingTimeInterval(300))
        return response
    }

    /// Checks if a query is allowed under the 100 queries/sec rate limit.
    public func allowQuery(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowQueryUnderLock(now: now)
    }

    private func allowQueryUnderLock(now: Date = Date()) -> Bool {
        let oneSecAgo = now.addingTimeInterval(-1.0)
        queryTimestamps = queryTimestamps.filter { $0 > oneSecAgo }
        guard queryTimestamps.count < maxQueriesPerSecond else { return false }
        queryTimestamps.append(now)
        return true
    }

    /// Selects next available upstream resolver avoiding failed servers.
    public func resolveWithFallback(failedServers: Set<String>) -> String? {
        for server in upstreamResolvers {
            if !failedServers.contains(server) {
                return server
            }
        }
        return nil
    }
}

// MARK: - Aliases for Test Compatibility

public typealias LocalDNSProxySimulator = DNSProxy
