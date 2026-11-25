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

    /// Performs a probe against the target host, attempting fast TCP connect probes first (with ping fallback).
    /// - Parameters:
    ///   - host: Hostname or IPv4/IPv6 address.
    ///   - port: TCP port to probe (defaults to 80, with concurrent 443 fallback when 80 is specified).
    ///   - timeout: Maximum wait time in seconds.
    /// - Returns: `ProbeResult` containing reachability, latency, packet loss, and timestamp.
    public func probe(
        target host: String,
        port: Int = 80,
        timeout: TimeInterval = 2.0
    ) async -> ProbeResult {
        let startTime = Date()
        let resolvedIP = await resolveHostToIPAsync(host)
        let connectTarget = resolvedIP ?? host
        let tcpTimeout = min(0.5, max(0.05, timeout))

        // Try crisp TCP socket connect probe (and 443 concurrently if default port 80)
        if port == 80 {
            async let port80 = tcpConnectProbe(host: connectTarget, port: 80, timeout: tcpTimeout)
            async let port443 = tcpConnectProbe(host: connectTarget, port: 443, timeout: tcpTimeout)
            let (lat80, lat443) = await (port80, port443)
            if let tcpLatency = lat80 ?? lat443 {
                return ProbeResult(
                    targetHost: host,
                    targetIP: resolvedIP,
                    isReachable: true,
                    latencyMs: tcpLatency,
                    packetLossPercent: 0.0,
                    timestamp: startTime
                )
            }
        } else if let tcpLatency = await tcpConnectProbe(host: connectTarget, port: port, timeout: tcpTimeout) {
            return ProbeResult(
                targetHost: host,
                targetIP: resolvedIP,
                isReachable: true,
                latencyMs: tcpLatency,
                packetLossPercent: 0.0,
                timestamp: startTime
            )
        }

        // Fallback: fast ICMP ping command probe
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

    /// Runs `/usr/sbin/traceroute -n -m <maxHops> -w 1 <target>` and returns non-empty output lines.
    public func traceroute(target: String, maxHops: Int = 12) async -> [String] {
        guard Self.isSafeHostToken(target) else { return [] }
        let clampedHops = max(1, min(64, maxHops))
        do {
            let output = try await ShellCommand.run(
                "/usr/sbin/traceroute",
                arguments: ["-n", "-m", String(clampedHops), "-w", "1", target],
                timeout: TimeInterval(clampedHops + 3)
            )
            let lines = output.stdout
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return lines
        } catch {
            return []
        }
    }

    // MARK: - TCP Socket Connect Probe

    private func tcpConnectProbe(host: String, port: Int, timeout: TimeInterval) async -> Double? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = DispatchTime.now()

                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP

                var res: UnsafeMutablePointer<addrinfo>?
                let portStr = String(port)
                guard getaddrinfo(host, portStr, &hints, &res) == 0, let addr = res else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(res) }

                let timeoutMs = Int32(max(1, Int(ceil(timeout * 1000.0))))
                var cursor: UnsafeMutablePointer<addrinfo>? = addr

                while let current = cursor {
                    let info = current.pointee
                    cursor = current.pointee.ai_next

                    let sock = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
                    guard sock >= 0 else { continue }
                    defer { close(sock) }

                    let flags = fcntl(sock, F_GETFL, 0)
                    if flags >= 0 {
                        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
                    }

                    let connRes = connect(sock, info.ai_addr, info.ai_addrlen)
                    if connRes == 0 {
                        let end = DispatchTime.now()
                        let nano = end.uptimeNanoseconds - start.uptimeNanoseconds
                        continuation.resume(returning: Double(nano) / 1_000_000.0)
                        return
                    }

                    guard errno == EINPROGRESS else { continue }

                    var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                    var pollRes: Int32 = 0
                    repeat {
                        pollRes = Darwin.poll(&pfd, 1, timeoutMs)
                    } while pollRes < 0 && errno == EINTR

                    if pollRes > 0 && (pfd.revents & Int16(POLLOUT | POLLERR | POLLHUP)) != 0 {
                        var error: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(sock, SOL_SOCKET, SO_ERROR, &error, &len) == 0 && error == 0 {
                            let end = DispatchTime.now()
                            let nano = end.uptimeNanoseconds - start.uptimeNanoseconds
                            continuation.resume(returning: Double(nano) / 1_000_000.0)
                            return
                        }
                    }
                }

                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - ICMP Ping Probe

    private func pingProbe(host: String, timeout: TimeInterval) async -> (isReachable: Bool, latencyMs: Double, packetLossPercent: Double, targetIP: String?) {
        guard Self.isSafeHostToken(host) else {
            return (false, 0.0, 100.0, nil)
        }
        do {
            let waitMs = max(200, min(1000, Int(ceil(timeout * 500.0))))
            let output = try await ShellCommand.run(
                "/sbin/ping",
                arguments: ["-c", "2", "-i", "0.2", "-W", String(waitMs), host],
                timeout: max(1.5, timeout + 0.5)
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

    private func resolveHostToIPAsync(_ host: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.resolveHostToIP(host))
            }
        }
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

    private static func isSafeHostToken(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("-") else { return false }
        return host.range(of: "^[A-Za-z0-9.:_-]+$", options: .regularExpression) != nil
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
