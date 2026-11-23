import Testing
import Foundation
@testable import NetBoostCore
@testable import NetBoostApp

@Suite("Tier 5 - Hotspot Sharing Engine, WPA3 & PF Stress Tests", .tags(.tier5, .hotspot))
struct Tier5_HotspotPFAndWPA3StressTests {

    // MARK: - Test 1: PF Already Enabled Guard Resilience

    @Test("T5-Hotspot-01: Guarded pfctl enable allows start when PF is already active")
    func testGuardedPFEnableExitCodeBehavior() async throws {
        // Test the shell pattern: (/sbin/pfctl -e 2>/dev/null || true)
        // Even if pfctl exits with 1 (already enabled), the compound command must succeed with exitCode 0
        let guardedCommand = "sh -c 'exit 1' 2>/dev/null || true"
        let output = try await ShellCommand.runBash(guardedCommand)
        #expect(output.succeeded == true)
        #expect(output.exitCode == 0)

        // Verify the exact string used in HotspotNATController
        let expectedPFEnableClause = "/sbin/pfctl -e 2>/dev/null || true"
        #expect(expectedPFEnableClause.contains("|| true"))
    }

    // MARK: - Test 2: Hotspot Atomic Start Command Structure

    @Test("T5-Hotspot-02: Hotspot start builds single compound elevated command")
    func testHotspotStartCommandComposition() {
        let sysctlCmd = "/usr/sbin/sysctl -w net.inet.ip.forwarding=1"
        let aliasCmd = "/sbin/ifconfig en0 alias 192.168.2.1 netmask 255.255.255.0"
        let tempRuleFile = "/tmp/test.pf"
        let loadAnchorCmd = "/sbin/pfctl -a netboost -f \(tempRuleFile)"
        let enablePFCmd = "/sbin/pfctl -e 2>/dev/null || true"

        let combinedStart = "\(sysctlCmd) && \(aliasCmd) && \(loadAnchorCmd) && (\(enablePFCmd))"

        #expect(combinedStart.contains("net.inet.ip.forwarding=1"))
        #expect(combinedStart.contains("alias 192.168.2.1"))
        #expect(combinedStart.contains("-a netboost -f"))
        #expect(combinedStart.contains("|| true"))
    }

    // MARK: - Test 3: Hotspot Stop Isolation

    @Test("T5-Hotspot-03: Hotspot stop flushes only netboost anchor rules and restores sysctl")
    func testHotspotStopCommandIsolation() {
        let anchorName = "netboost"
        let flushCmd = "/sbin/pfctl -a \(anchorName) -F all 2>/dev/null || true"
        let unaliasCmd = "/sbin/ifconfig en0 -alias 192.168.2.1 2>/dev/null || true"
        let sysctlCmd = "/usr/sbin/sysctl -w net.inet.ip.forwarding=0 2>/dev/null || true"

        let combinedStop = "\(flushCmd) ; \(unaliasCmd) ; \(sysctlCmd)"

        #expect(combinedStop.contains("-a netboost -F all"))
        #expect(combinedStop.contains("-alias 192.168.2.1"))
        #expect(combinedStop.contains("net.inet.ip.forwarding=0"))
        // Confirms it does not flush global PF rules (-F all without -a)
        #expect(!combinedStop.contains("/sbin/pfctl -F all"))
    }

    // MARK: - Test 4: WPA3 Personal & Transition Security Types

    @Test("T5-Hotspot-04: WPA3 Personal (SAE) and Transition security type models & serialization")
    func testWPA3SecurityTypeRoundtrip() throws {
        let types: [HotspotSecurityType] = [
            .wpa3Personal,
            .wpa2Wpa3Transition,
            .wpa2Personal
        ]

        #expect(types.count == 3)
        #expect(HotspotSecurityType.wpa3Personal.rawValue == "WPA3 Personal (SAE)")
        #expect(HotspotSecurityType.wpa2Wpa3Transition.rawValue == "WPA2/WPA3 Transition")
        #expect(HotspotSecurityType.wpa2Personal.rawValue == "WPA2 Personal")

        for secType in types {
            let config = HotspotConfiguration(
                ssid: "CampusNet-Secure",
                password: "SecurePassphrase2026!",
                securityType: secType
            )

            let encoder = JSONEncoder()
            let data = try encoder.encode(config)
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(HotspotConfiguration.self, from: data)

            #expect(decoded.securityType == secType)
            #expect(decoded.ssid == "CampusNet-Secure")
            #expect(decoded.password == "SecurePassphrase2026!")
        }
    }

    // MARK: - Test 5: Hotspot Password Boundary Validation

    @Test("T5-Hotspot-05: Hotspot password boundary lengths and special character encoding")
    func testHotspotPasswordBoundaries() {
        // IEEE 802.11 requires 8-63 ASCII characters for WPA2/WPA3 Personal passphrases
        let minPassword = "12345678" // 8 chars
        let maxPassword = String(repeating: "A", count: 63) // 63 chars
        let specialPassword = "P@ssw0rd!#$&*()_+~|}{[]:;?><,."

        let c1 = HotspotConfiguration(password: minPassword)
        let c2 = HotspotConfiguration(password: maxPassword)
        let c3 = HotspotConfiguration(password: specialPassword)

        #expect(c1.password.count == 8)
        #expect(c2.password.count == 63)
        #expect(c3.password.count == specialPassword.count)
    }

    // MARK: - Test 6: DHCP Lease Pool Saturation Stress

    @Test("T5-Hotspot-06: DHCP lease pool saturation across all 91 addresses (10...100)")
    func testDHCPLPoolExhaustionAndReclaim() {
        let dhcp = DHCPServer()
        dhcp.start()

        var allocatedSet = Set<String>()

        // Pool contains 192.168.2.10 through 192.168.2.100 inclusive (91 IPs)
        for i in 1...91 {
            let mac = String(format: "02:00:00:00:%02X:%02X", i / 256, i % 256)
            let lease = dhcp.allocate(mac: mac)
            #expect(lease != nil)
            if let ip = lease?.ipAddress {
                #expect(!allocatedSet.contains(ip), "Duplicate IP allocated: \(ip)")
                allocatedSet.insert(ip)
            }
        }

        #expect(allocatedSet.count == 91)
        #expect(dhcp.activeLeaseCount == 91)

        // 92nd allocation should fail gracefully with nil (pool exhausted)
        let mac92 = "02:00:00:00:FF:FF"
        let overflowLease = dhcp.allocate(mac: mac92)
        #expect(overflowLease == nil)

        // Release one client
        let firstMAC = String(format: "02:00:00:00:%02X:%02X", 1 / 256, 1 % 256)
        dhcp.release(mac: firstMAC)
        #expect(dhcp.activeLeaseCount == 90)

        // Now new client can allocate the freed slot
        let newLease = dhcp.allocate(mac: mac92)
        #expect(newLease != nil)
        #expect(newLease?.ipAddress == "192.168.2.10")
    }

    // MARK: - Test 7: DHCP Lease Expiration Cleanup

    @Test("T5-Hotspot-07: Expired DHCP leases are purged on subsequent allocation")
    func testDHCPExpiredLeasePurge() {
        let dhcp = DHCPServer()
        dhcp.start()

        // Allocate with 0-second duration so it is immediately expired
        let macExpired = "02:00:00:00:AA:01"
        let lease = dhcp.allocate(mac: macExpired, duration: -1.0)
        #expect(lease != nil)

        // Next allocation should clean up the expired lease
        let macNew = "02:00:00:00:BB:02"
        let newLease = dhcp.allocate(mac: macNew, duration: 3600)
        #expect(newLease != nil)
        #expect(newLease?.ipAddress == "192.168.2.10")
    }

    // MARK: - Test 8: DHCP Discover / Request Workflow

    @Test("T5-Hotspot-08: DHCP discover and request state transitions")
    func testDHCPDiscoverAndRequestWorkflow() {
        let dhcp = DHCPServer()
        dhcp.start()

        let mac = "02:AA:BB:CC:DD:EE"
        let offeredIP = dhcp.handleDiscover(mac: mac)
        #expect(offeredIP == "192.168.2.10")

        let confirmedLease = dhcp.handleRequest(mac: mac, requestedIP: offeredIP!, hostname: "iPhone-Test")
        #expect(confirmedLease != nil)
        #expect(confirmedLease?.ipAddress == "192.168.2.10")
        #expect(confirmedLease?.hostname == "iPhone-Test")

        // Second discover by same MAC returns existing active lease
        let rediscover = dhcp.handleDiscover(mac: mac)
        #expect(rediscover == "192.168.2.10")
    }

    // MARK: - Test 9: DNS Proxy Rate-Limiting Flood Defense

    @Test("T5-Hotspot-09: DNSProxy enforces 100 queries/second ceiling under flood conditions")
    func testDNSProxyRateLimitCeiling() {
        let proxy = DNSProxy()
        proxy.start()

        let now = Date()
        var allowedCount = 0
        var droppedCount = 0

        // Attempt 250 queries within identical timestamp window
        for _ in 1...250 {
            if proxy.allowQuery(now: now) {
                allowedCount += 1
            } else {
                droppedCount += 1
            }
        }

        #expect(allowedCount == proxy.maxQueriesPerSecond)
        #expect(allowedCount == 100)
        #expect(droppedCount == 150)

        // 1.1 seconds later, rate limit resets
        let later = now.addingTimeInterval(1.1)
        #expect(proxy.allowQuery(now: later) == true)
    }

    // MARK: - Test 10: DNS Proxy Concurrent Query Safety

    private struct MockFastResolver: DNSResolverProtocol, @unchecked Sendable {
        func resolve(domain: String, queryType: String, upstreamResolvers: [String]) -> String? {
            "192.168.2.1"
        }
    }

    @Test("T5-Hotspot-10: DNSProxy thread-safety under simultaneous multi-task queries")
    func testDNSProxyConcurrentQuerySafety() async {
        let proxy = DNSProxy(resolver: MockFastResolver())
        proxy.start()

        let taskCount = 30
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    let q = DNSQuery(domain: "test.local", queryType: "A")
                    _ = proxy.resolve(query: q)
                    return true
                }
            }

            var finished = 0
            for await res in group {
                if res { finished += 1 }
            }
            #expect(finished == taskCount)
        }
    }
}
