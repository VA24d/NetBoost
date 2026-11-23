import Testing
import Foundation
@testable import NetBoostCore

@Suite("Hotspot Sharing: DNSProxy Unit & Integration Tests")
struct DNSProxyTests {

    struct MockDNSResolver: DNSResolverProtocol {
        let returnIP: String
        func resolve(domain: String, queryType: String, upstreamResolvers: [String]) -> String? {
            return returnIP
        }
    }

    @Test("DNS proxy lifecycle start and stop")
    func testProxyLifecycle() {
        let proxy = DNSProxy()
        #expect(proxy.isRunning == false)

        proxy.start()
        #expect(proxy.isRunning == true)

        proxy.stop()
        #expect(proxy.isRunning == false)
    }

    @Test("Resolve domain query returns resolved IP and TTL")
    func testResolveDomainQuery() {
        let proxy = DNSProxy()
        proxy.start()
        defer { proxy.stop() }

        let query = DNSQuery(domain: "turing.iiit.ac.in", queryType: "A")
        let response = proxy.resolve(query: query)

        #expect(response.domain == "turing.iiit.ac.in")
        #expect(response.resolvedIP == "10.8.0.80")
        #expect(response.ttl == 300)
    }

    @Test("DNS proxy caches query responses within TTL")
    func testDNSProxyCaching() {
        let proxy = DNSProxy()
        proxy.start()
        defer { proxy.stop() }

        let query = DNSQuery(domain: "turing.iiit.ac.in", queryType: "A")
        let res1 = proxy.resolve(query: query)
        let res2 = proxy.resolve(query: query)

        #expect(res1.resolvedIP == "10.8.0.80")
        #expect(res1 == res2)
    }

    @Test("Injectable DNS resolver enables offline and mock query testing")
    func testMockDNSResolverInjection() {
        let mockResolver = MockDNSResolver(returnIP: "192.168.100.50")
        let proxy = DNSProxy(resolver: mockResolver)
        proxy.start()
        defer { proxy.stop() }

        let query = DNSQuery(domain: "custom.internal", queryType: "A")
        let response = proxy.resolve(query: query)

        #expect(response.domain == "custom.internal")
        #expect(response.resolvedIP == "192.168.100.50")
        #expect(response.ttl == 300)
    }

    @Test("Fallback resolver chain selects secondary when primary fails")
    func testFallbackResolverChain() {
        let proxy = DNSProxy(upstreamResolvers: ["10.4.20.21", "10.4.20.222", "1.1.1.1"])

        // When primary 10.4.20.21 fails
        let chosen1 = proxy.resolveWithFallback(failedServers: ["10.4.20.21"])
        #expect(chosen1 == "10.4.20.222")

        // When both campus servers fail
        let chosen2 = proxy.resolveWithFallback(failedServers: ["10.4.20.21", "10.4.20.222"])
        #expect(chosen2 == "1.1.1.1")

        // When all servers fail
        let chosen3 = proxy.resolveWithFallback(failedServers: ["10.4.20.21", "10.4.20.222", "1.1.1.1"])
        #expect(chosen3 == nil)
    }

    @Test("Rate limiter permits up to 100 queries/sec and throttles excess")
    func testRateLimiting() {
        let proxy = DNSProxy()
        proxy.start()
        defer { proxy.stop() }

        let testTime = Date()
        for _ in 0..<100 {
            #expect(proxy.allowQuery(now: testTime) == true)
        }

        // 101st query in same second is rate-limited
        #expect(proxy.allowQuery(now: testTime) == false)

        // Query 2 seconds later succeeds
        let laterTime = testTime.addingTimeInterval(2.0)
        #expect(proxy.allowQuery(now: laterTime) == true)
    }
}
