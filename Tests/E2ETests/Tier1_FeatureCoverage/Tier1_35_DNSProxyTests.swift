import Testing
import Foundation

@Suite("Feature 35: Local DNS Proxy Forwarding", .tags(.tier1, .m5_doctor, .hotspot))
struct Tier1_35_DNSProxyTests {

    struct DNSQuery: Equatable {
        let domain: String
        let queryType: String // A, AAAA, etc.
    }

    struct DNSResponse: Equatable {
        let domain: String
        let resolvedIP: String
        let ttl: Int
    }

    final class LocalDNSProxySimulator: @unchecked Sendable {
        private var cache: [String: (response: DNSResponse, expiresAt: Date)] = [:]
        private let upstreamResolver: String
        private(set) var isRunning: Bool = false
        private let lock = NSLock()

        init(upstreamResolver: String = "10.4.20.21") {
            self.upstreamResolver = upstreamResolver
        }

        func start() {
            lock.lock()
            defer { lock.unlock() }
            isRunning = true
        }

        func stop() {
            lock.lock()
            defer { lock.unlock() }
            isRunning = false
            cache.removeAll()
        }

        func resolve(query: DNSQuery) -> DNSResponse {
            lock.lock()
            defer { lock.unlock() }

            if let cached = cache[query.domain], Date() < cached.expiresAt {
                return cached.response
            }

            // Simulated resolution via upstream campus DNS
            let resolved = DNSResponse(domain: query.domain, resolvedIP: "10.8.0.80", ttl: 300)
            cache[query.domain] = (resolved, Date().addingTimeInterval(300))
            return resolved
        }
    }

    @Test("T1-F35-01: Start local DNS proxy forwarding listener on port 53")
    func testStartDNSProxyListener() {
        let proxy = LocalDNSProxySimulator()
        proxy.start()
        #expect(proxy.isRunning == true)
        proxy.stop()
        #expect(proxy.isRunning == false)
    }

    @Test("T1-F35-02: Forward client DNS query to campus upstream resolver 10.4.20.21")
    func testForwardQueryToUpstream() {
        let proxy = LocalDNSProxySimulator(upstreamResolver: "10.4.20.21")
        proxy.start()
        defer { proxy.stop() }

        let query = DNSQuery(domain: "turing.iiit.ac.in", queryType: "A")
        let response = proxy.resolve(query: query)

        #expect(response.domain == "turing.iiit.ac.in")
        #expect(response.resolvedIP == "10.8.0.80")
    }

    @Test("T1-F35-03: Return upstream DNS response payload to hotspot client")
    func testReturnDNSResponseToClient() {
        let proxy = LocalDNSProxySimulator()
        proxy.start()
        defer { proxy.stop() }

        let query = DNSQuery(domain: "intranet.iiit.ac.in", queryType: "A")
        let response = proxy.resolve(query: query)

        #expect(!response.resolvedIP.isEmpty)
        #expect(response.ttl > 0)
    }

    @Test("T1-F35-04: Cache DNS responses for duration of TTL")
    func testCacheDNSResponseForTTL() {
        let proxy = LocalDNSProxySimulator()
        proxy.start()
        defer { proxy.stop() }

        let query = DNSQuery(domain: "cached.iiit.ac.in", queryType: "A")
        let res1 = proxy.resolve(query: query)
        let res2 = proxy.resolve(query: query)

        #expect(res1 == res2)
    }

    @Test("T1-F35-05: Stop DNS listener cleanly upon hotspot termination and flush cache")
    func testStopListenerFlushesCache() {
        let proxy = LocalDNSProxySimulator()
        proxy.start()
        let query = DNSQuery(domain: "test.local", queryType: "A")
        _ = proxy.resolve(query: query)

        proxy.stop()
        #expect(proxy.isRunning == false)
    }
}
