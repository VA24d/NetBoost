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

        let parts = domain.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard let ascii = part.data(using: .ascii), ascii.count <= 63 else { return nil }
            packet.append(UInt8(ascii.count))
            packet.append(contentsOf: ascii)
        }
        packet.append(0x00) // Terminating null

        let qType: UInt16 = (queryType.uppercased() == "AAAA") ? 28 : 1
        packet.append(UInt8(qType >> 8))
        packet.append(UInt8(qType & 0xFF))
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

/// Errors thrown by the DNSProxy UDP socket listener.
public enum DNSProxyError: Error, LocalizedError, Sendable, Equatable {
    case socketCreationFailed(errno: Int32, message: String)
    case bindFailed(port: UInt16, errno: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let code, let msg):
            return "Failed to create DNS UDP socket (errno \(code)): \(msg)"
        case .bindFailed(let port, let code, let msg):
            return "Failed to bind DNS UDP socket on port \(port) (errno \(code)): \(msg)"
        }
    }
}

/// Local DNS proxy forwarding DNS queries from hotspot clients to campus DNS resolvers (10.4.20.21, 10.4.20.222).
public final class DNSProxy: @unchecked Sendable {

    public static let defaultUpstreamResolvers = ["10.4.20.21", "10.4.20.222", "1.1.1.1"]

    private var cache: [String: (response: DNSResponse, expiresAt: Date)] = [:]
    private let upstreamResolvers: [String]
    private let resolver: DNSResolverProtocol
    private var _isRunning: Bool = false
    public var isRunning: Bool {
        lock.withLock { _isRunning }
    }
    private let lock = NSLock()

    // Rate limiting tracking
    private var queryTimestamps: [Date] = []
    public let maxQueriesPerSecond: Int = 100

    // Non-blocking UDP listener state
    private let udpQueue = DispatchQueue(label: "com.netboost.dnsproxy.udp", qos: .userInitiated)
    private let udpQueueKey = DispatchSpecificKey<UInt8>()
    private var udpSocketFD: Int32 = -1
    private var udpReadSource: DispatchSourceRead?
    private var udpCancelGroup: DispatchGroup?
    private var _listeningPort: UInt16?

    public var listeningPort: UInt16? {
        lock.withLock { _listeningPort }
    }

    public init(
        upstreamResolvers: [String] = defaultUpstreamResolvers,
        resolver: DNSResolverProtocol? = nil
    ) {
        self.upstreamResolvers = upstreamResolvers
        self.resolver = resolver ?? DarwinDNSResolver()
        self.udpQueue.setSpecific(key: udpQueueKey, value: 1)
    }

    public convenience init(
        upstreamResolver: String,
        resolver: DNSResolverProtocol? = nil
    ) {
        self.init(upstreamResolvers: [upstreamResolver, "10.4.20.222", "1.1.1.1"], resolver: resolver)
    }

    deinit {
        stopUDPListener()
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        _isRunning = true
    }

    public func stop() {
        stopUDPListener()
        lock.lock()
        defer { lock.unlock() }
        _isRunning = false
        cache.removeAll()
        queryTimestamps.removeAll()
    }

    /// Resolves DNS query with caching, genuine upstream resolution, and rate-limiting.
    public func resolve(query: DNSQuery) -> DNSResponse {
        lock.lock()
        defer { lock.unlock() }

        guard allowQueryUnderLock() else {
            return DNSResponse(domain: query.domain, resolvedIP: "", ttl: 0)
        }

        let cacheKey = "\(query.domain.lowercased())|\(query.queryType.uppercased())"

        if let cached = cache[cacheKey], Date() < cached.expiresAt {
            return cached.response
        }

        guard let resolvedIP = resolver.resolve(
            domain: query.domain,
            queryType: query.queryType,
            upstreamResolvers: upstreamResolvers
        ), !resolvedIP.isEmpty else {
            return DNSResponse(domain: query.domain, resolvedIP: "", ttl: 0)
        }

        let response = DNSResponse(domain: query.domain, resolvedIP: resolvedIP, ttl: 300)
        cache[cacheKey] = (response, Date().addingTimeInterval(300))
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

    // MARK: - Non-Blocking Darwin UDP Listener (RFC 1035)

    /// Starts a non-blocking Darwin `SOCK_DGRAM` DNS UDP listener on the specified port (default 53) on a background queue.
    public func startUDPListener(port: UInt16 = 53) throws {
        stopUDPListener()

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            let code = errno
            throw DNSProxyError.socketCreationFailed(errno: code, message: String(cString: strerror(code)))
        }

        var reuse: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

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
            throw DNSProxyError.bindFailed(port: port, errno: code, message: String(cString: strerror(code)))
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
            self._isRunning = true
        }

        source.resume()
    }

    /// Stops the non-blocking DNS UDP listener and closes its socket cleanly.
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
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var fromAddr = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let bytesRead = withUnsafeMutablePointer(to: &fromAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.recvfrom(fd, &buffer, buffer.count, 0, sa, &fromLen)
                }
            }
            if bytesRead <= 0 {
                break
            }

            let packetData = Data(buffer[0..<bytesRead])
            guard let responseData = handleUDPPacket(packetData) else { continue }

            _ = responseData.withUnsafeBytes { rawBuf in
                withUnsafePointer(to: &fromAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.sendto(fd, rawBuf.baseAddress, responseData.count, 0, sa, fromLen)
                    }
                }
            }
        }
    }

    /// Parses a standard DNS UDP query packet, delegates resolution to `resolve(query:)`, and returns a DNS A/AAAA wire response.
    public func handleUDPPacket(_ packetData: Data) -> Data? {
        let bytes = [UInt8](packetData)
        guard bytes.count >= 17 else { return nil }

        let qdCount = (UInt16(bytes[4]) << 8) | UInt16(bytes[5])
        guard qdCount >= 1 else { return nil }

        var labels: [String] = []
        var offset = 12
        while offset < bytes.count {
            let labelLen = Int(bytes[offset])
            if labelLen == 0 {
                offset += 1
                break
            }
            // Reject compressed pointers in question section
            guard (labelLen & 0xC0) == 0, offset + 1 + labelLen <= bytes.count else {
                return nil
            }
            let labelBytes = bytes[(offset + 1)..<(offset + 1 + labelLen)]
            guard let label = String(bytes: labelBytes, encoding: .ascii) else { return nil }
            labels.append(label)
            offset += 1 + labelLen
        }

        guard !labels.isEmpty, offset + 4 <= bytes.count else { return nil }
        let qType = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        let qClass = (UInt16(bytes[offset + 2]) << 8) | UInt16(bytes[offset + 3])
        let questionEnd = offset + 4

        let domain = labels.joined(separator: ".")
        let queryTypeStr: String? = switch qType {
        case 1: "A"
        case 28: "AAAA"
        default: nil
        }

        var response = [UInt8]()
        response.append(bytes[0]) // ID hi
        response.append(bytes[1]) // ID lo
        let reqRD = bytes[2] & 0x01
        let reqOpcode = bytes[2] & 0x78
        let respByte2: UInt8 = 0x80 | reqOpcode | reqRD // QR=1, Opcode, RD

        var rdataBytes: [UInt8]?
        if let qTypeStr = queryTypeStr, qClass == 1 {
            let resolved = resolve(query: DNSQuery(domain: domain, queryType: qTypeStr))
            if !resolved.resolvedIP.isEmpty {
                if qType == 1 {
                    var addr4 = in_addr()
                    if inet_pton(AF_INET, resolved.resolvedIP, &addr4) == 1 {
                        rdataBytes = withUnsafeBytes(of: &addr4) { Array($0) }
                    }
                } else if qType == 28 {
                    var addr6 = in6_addr()
                    if inet_pton(AF_INET6, resolved.resolvedIP, &addr6) == 1 {
                        rdataBytes = withUnsafeBytes(of: &addr6) { Array($0) }
                    }
                }
            }

            let ttl = UInt32(max(0, resolved.ttl))
            if let rdata = rdataBytes {
                response.append(respByte2)
                response.append(0x80) // RA=1, RCODE=0 (NOERROR)
                response.append(contentsOf: [0x00, 0x01]) // QDCOUNT = 1
                response.append(contentsOf: [0x00, 0x01]) // ANCOUNT = 1
                response.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // NSCOUNT, ARCOUNT
                response.append(contentsOf: bytes[12..<questionEnd])
                // Answer RR: NAME pointer to offset 12 (0xC00C)
                response.append(contentsOf: [0xC0, 0x0C])
                response.append(UInt8(qType >> 8))
                response.append(UInt8(qType & 0xFF))
                response.append(contentsOf: [0x00, 0x01]) // CLASS = IN
                response.append(contentsOf: [
                    UInt8((ttl >> 24) & 0xFF),
                    UInt8((ttl >> 16) & 0xFF),
                    UInt8((ttl >> 8) & 0xFF),
                    UInt8(ttl & 0xFF)
                ])
                response.append(UInt8(rdata.count >> 8))
                response.append(UInt8(rdata.count & 0xFF))
                response.append(contentsOf: rdata)
                return Data(response)
            } else {
                // SERVFAIL (RCODE = 2)
                response.append(respByte2)
                response.append(0x82) // RA=1, RCODE=2
                response.append(contentsOf: [0x00, 0x01]) // QDCOUNT = 1
                response.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // ANCOUNT=0, NSCOUNT=0, ARCOUNT=0
                response.append(contentsOf: bytes[12..<questionEnd])
                return Data(response)
            }
        } else {
            // Unsupported QTYPE/QCLASS: NOERROR with 0 answers
            response.append(respByte2)
            response.append(0x80)
            response.append(contentsOf: [0x00, 0x01])
            response.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            response.append(contentsOf: bytes[12..<questionEnd])
            return Data(response)
        }
    }
}

// MARK: - Aliases for Test Compatibility

public typealias LocalDNSProxySimulator = DNSProxy
