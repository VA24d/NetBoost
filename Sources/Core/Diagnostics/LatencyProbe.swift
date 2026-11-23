import Foundation
import Darwin
import Network

/// Probes network endpoints using socket-level TCP connects and ICMP ping probes.
public final class LatencyProbe: Sendable {

    /// Standard campus and external diagnostic targets
    public static let localGateway = "10.1.36.1"
    public static let campusCore = "10.8.0.80"
    public static let turingHPC = "turing.iiit.ac.in"
    public static let google = "google.com"
    public static let claude = "claude.com"

    public static let defaultTargets = [
        localGateway,
        campusCore,
        turingHPC,
        google,
        claude
    ]

    public init() {}

    /// Performs a probe against the target host, attempting a TCP connect probe first (or ping fallback).
    /// - Parameters:
    ///   - host: Hostname or IPv4/IPv6 address.
    ///   - port: TCP port to probe (defaults to 80 for HTTP, 443 for HTTPS, or 53/common services).
    ///   - timeout: Maximum wait time in seconds.
    /// - Returns: `ProbeResult` containing reachability, latency, packet loss, and timestamp.
    public func probe(
        target host: String,
        port: Int = 80,
        timeout: TimeInterval = 2.0
    ) async -> ProbeResult {
        let startTime = Date()

        // Resolve IP if possible
        let resolvedIP = resolveHostToIP(host)

        // Try TCP socket connect probe
        if let tcpLatency = await tcpConnectProbe(host: resolvedIP ?? host, port: port, timeout: timeout) {
            return ProbeResult(
                targetHost: host,
                targetIP: resolvedIP,
                isReachable: true,
                latencyMs: tcpLatency,
                packetLossPercent: 0.0,
                timestamp: startTime
            )
        }

        // Fallback: ping command probe
        let pingResult = await pingProbe(host: host, timeout: timeout)
        return ProbeResult(
            targetHost: host,
            targetIP: resolvedIP ?? pingResult.targetIP,
            isReachable: pingResult.isReachable,
            latencyMs: pingResult.latencyMs,
            packetLossPercent: pingResult.packetLossPercent,
            timestamp: startTime
        )
    }

    /// Performs probes across all provided targets concurrently.
    public func probeAll(
        targets: [String] = defaultTargets,
        timeout: TimeInterval = 2.0
    ) async -> [String: ProbeResult] {
        await withTaskGroup(of: (String, ProbeResult).self) { group in
            for target in targets {
                group.addTask {
                    let result = await self.probe(target: target, timeout: timeout)
                    return (target, result)
                }
            }

            var results: [String: ProbeResult] = [:]
            for await (target, result) in group {
                results[target] = result
            }
            return results
        }
    }

    // MARK: - TCP Socket Connect Probe

    private func tcpConnectProbe(host: String, port: Int, timeout: TimeInterval) async -> Double? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = DispatchTime.now()

                var hints = addrinfo()
                hints.ai_family = AF_INET // IPv4
                hints.ai_socktype = SOCK_STREAM

                var res: UnsafeMutablePointer<addrinfo>?
                let portStr = String(port)
                guard getaddrinfo(host, portStr, &hints, &res) == 0, let addr = res else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(res) }

                let sock = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
                guard sock >= 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { close(sock) }

                // Set non-blocking for connect timeout
                let flags = fcntl(sock, F_GETFL, 0)
                _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

                let connRes = connect(sock, addr.pointee.ai_addr, addr.pointee.ai_addrlen)
                if connRes == 0 {
                    let end = DispatchTime.now()
                    let nano = end.uptimeNanoseconds - start.uptimeNanoseconds
                    continuation.resume(returning: Double(nano) / 1_000_000.0)
                    return
                }

                if errno != EINPROGRESS {
                    continuation.resume(returning: nil)
                    return
                }

                // Poll with select for timeout
                var fdSet = fd_set()
                fdSet.zero()
                fdSet.set(sock)

                var tv = timeval()
                tv.tv_sec = Int(timeout)
                tv.tv_usec = Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)

                let selRes = select(sock + 1, nil, &fdSet, nil, &tv)
                if selRes > 0 {
                    var error: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(sock, SOL_SOCKET, SO_ERROR, &error, &len) == 0 && error == 0 {
                        let end = DispatchTime.now()
                        let nano = end.uptimeNanoseconds - start.uptimeNanoseconds
                        continuation.resume(returning: Double(nano) / 1_000_000.0)
                        return
                    }
                }

                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - ICMP Ping Probe

    private func pingProbe(host: String, timeout: TimeInterval) async -> (isReachable: Bool, latencyMs: Double, packetLossPercent: Double, targetIP: String?) {
        do {
            let timeoutSec = max(1, Int(ceil(timeout)))
            let output = try await ShellCommand.run(
                "/sbin/ping",
                arguments: ["-c", "2", "-W", String(timeoutSec * 1000), host],
                timeout: timeout + 1.0
            )

            guard output.succeeded else {
                return (false, 0.0, 100.0, nil)
            }

            return parsePingOutput(output.stdout)
        } catch {
            return (false, 0.0, 100.0, nil)
        }
    }

    /// Parses ping standard output for packet loss, average latency, and target IP
    public func parsePingOutput(_ output: String) -> (isReachable: Bool, latencyMs: Double, packetLossPercent: Double, targetIP: String?) {
        var targetIP: String? = nil
        var packetLoss = 100.0
        var avgLatency = 0.0

        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            // PING turing.iiit.ac.in (10.8.0.80): 56 data bytes
            if line.hasPrefix("PING ") && targetIP == nil {
                if let startParen = line.firstIndex(of: "("),
                   let endParen = line.firstIndex(of: ")") {
                    targetIP = String(line[line.index(after: startParen)..<endParen])
                }
            }

            // 2 packets transmitted, 2 packets received, 0.0% packet loss
            if line.contains("packet loss") {
                let parts = line.split(separator: ",")
                for part in parts {
                    if part.contains("packet loss") {
                        let clean = part.replacingOccurrences(of: "% packet loss", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        if let loss = Double(clean) {
                            packetLoss = loss
                        }
                    }
                }
            }

            // round-trip min/avg/max/stddev = 1.234/1.567/2.012/0.312 ms
            if line.contains("round-trip") || line.contains("rtt") {
                if let eqIndex = line.firstIndex(of: "=") {
                    let metricsPart = line[line.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)
                    let components = metricsPart.split(separator: "/")
                    if components.count >= 2, let avg = Double(components[1]) {
                        avgLatency = avg
                    }
                }
            }
        }

        let isReachable = packetLoss < 100.0
        return (isReachable, avgLatency, packetLoss, targetIP)
    }

    private func resolveHostToIP(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var res: UnsafeMutablePointer<addrinfo>?

        if getaddrinfo(host, nil, &hints, &res) == 0, let addr = res {
            defer { freeaddrinfo(res) }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let sockAddrIn = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var sinAddr = sockAddrIn.sin_addr
            if inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                let nullTerminated = ipBuf.prefix(while: { $0 != 0 })
                return String(decoding: nullTerminated.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}

// MARK: - Simulation Helper (Conforms to EndpointRTTProber pattern)

public struct EndpointRTTProber: Sendable {
    public static func simulateProbe(
        target: String,
        ip: String? = nil,
        latency: Double = 1.5,
        isReachable: Bool = true,
        packetLoss: Double = 0.0
    ) -> ProbeResult {
        ProbeResult(
            targetHost: target,
            targetIP: ip,
            isReachable: isReachable,
            latencyMs: latency,
            packetLossPercent: packetLoss,
            timestamp: Date()
        )
    }
}

// Helper fd_set extensions
private extension fd_set {
    mutating func zero() {
        self = fd_set()
    }

    mutating func set(_ fd: Int32) {
        let intOffset = Int(fd / 32)
        let bitOffset = fd % 32
        let mask: Int32 = 1 << bitOffset
        withUnsafeMutableBytes(of: &self) { ptr in
            let bound = ptr.bindMemory(to: Int32.self)
            bound[intOffset] |= mask
        }
    }
}
