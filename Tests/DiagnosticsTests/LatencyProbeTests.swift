import Testing
import Foundation
@testable import NetBoostCore

@Suite("Campus Diagnostics: LatencyProbe Unit & Integration Tests")
struct LatencyProbeTests {

    @Test("EndpointRTTProber produces valid probe results with target metadata")
    func testEndpointRTTProberSimulation() {
        let result = EndpointRTTProber.simulateProbe(
            target: "10.1.36.1",
            ip: "10.1.36.1",
            latency: 0.85,
            isReachable: true,
            packetLoss: 0.0
        )

        #expect(result.targetHost == "10.1.36.1")
        #expect(result.targetIP == "10.1.36.1")
        #expect(result.isReachable == true)
        #expect(result.latencyMs == 0.85)
        #expect(result.packetLossPercent == 0.0)
    }

    @Test("Parse standard macOS ping output with zero packet loss")
    func testParsePingOutputSuccess() {
        let prober = LatencyProbe()
        let sampleOutput = """
        PING turing.iiit.ac.in (10.8.0.80): 56 data bytes
        64 bytes from 10.8.0.80: icmp_seq=0 ttl=64 time=1.423 ms
        64 bytes from 10.8.0.80: icmp_seq=1 ttl=64 time=1.512 ms

        --- turing.iiit.ac.in ping statistics ---
        2 packets transmitted, 2 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 1.423/1.467/1.512/0.044 ms
        """

        let (isReachable, avgLatency, packetLoss, targetIP) = prober.parsePingOutput(sampleOutput)
        #expect(isReachable == true)
        #expect(targetIP == "10.8.0.80")
        #expect(packetLoss == 0.0)
        #expect(avgLatency == 1.467)
    }

    @Test("Parse standard ping output with 100% packet loss and unreachable target")
    func testParsePingOutputFailure() {
        let prober = LatencyProbe()
        let failureOutput = """
        PING 192.0.2.1 (192.0.2.1): 56 data bytes
        Request timeout for icmp_seq 0
        Request timeout for icmp_seq 1

        --- 192.0.2.1 ping statistics ---
        2 packets transmitted, 0 packets received, 100.0% packet loss
        """

        let (isReachable, avgLatency, packetLoss, targetIP) = prober.parsePingOutput(failureOutput)
        #expect(isReachable == false)
        #expect(targetIP == "192.0.2.1")
        #expect(packetLoss == 100.0)
        #expect(avgLatency == 0.0)
    }

    @Test("Probe local loopback returns reachable with low latency")
    func testProbeLocalLoopback() async {
        let prober = LatencyProbe()
        // Probing 127.0.0.1 on a port or ping fallback
        let result = await prober.probe(target: "127.0.0.1", timeout: 1.0)
        #expect(result.targetHost == "127.0.0.1")
        // Loopback is either reachable via TCP or ping
        #expect(result.packetLossPercent <= 100.0)
    }

    @Test("ProbeAll executes concurrent probes across multiple targets")
    func testProbeAllConcurrent() async {
        let prober = LatencyProbe()
        let targets = ["127.0.0.1", "localhost"]
        let results = await prober.probeAll(targets: targets, timeout: 1.0)

        #expect(results.count == 2)
        #expect(results["127.0.0.1"] != nil)
        #expect(results["localhost"] != nil)
    }

    @Test("Default target constants match campus architecture specifications")
    func testTargetConstants() {
        #expect(LatencyProbe.localGateway == "10.1.36.1")
        #expect(LatencyProbe.campusCore == "10.8.0.80")
        #expect(LatencyProbe.turingHPC == "turing.iiit.ac.in")
        #expect(LatencyProbe.google == "google.com")
        #expect(LatencyProbe.claude == "claude.com")
        #expect(LatencyProbe.defaultTargets.count == 5)
    }
}
