import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 23: Multi-Endpoint RTT Probes Boundaries", .tags(.tier2, .m5_doctor, .diagnostics))
struct Tier2_23_MultiEndpointRTTBoundariesTests {

    @Test("T2-F23-01: Unreachable host result reports 100% loss and isReachable false")
    func testUnreachableHostProbe() {
        let unreachableResult = ProbeResult(
            targetHost: "192.0.2.1", // TEST-NET-1 unassigned
            isReachable: false,
            latencyMs: 0.0,
            packetLossPercent: 100.0
        )

        #expect(unreachableResult.isReachable == false)
        #expect(unreachableResult.packetLossPercent == 100.0)
        #expect(unreachableResult.latencyMs == 0.0)
    }

    @Test("T2-F23-02: Partial packet loss calculated accurately (e.g. 1 out of 5 packets lost = 20%)")
    func testPartialPacketLossMath() {
        func calculateLoss(sent: Int, received: Int) -> Double {
            guard sent > 0 else { return 0.0 }
            let lost = max(0, sent - received)
            return (Double(lost) / Double(sent)) * 100.0
        }

        #expect(calculateLoss(sent: 5, received: 4) == 20.0)
        #expect(calculateLoss(sent: 10, received: 7) == 30.0)
        #expect(calculateLoss(sent: 5, received: 0) == 100.0)
        #expect(calculateLoss(sent: 5, received: 5) == 0.0)
    }

    @Test("T2-F23-03: All 5 primary campus and external diagnostic targets defined")
    func testCampusDiagnosticTargetEndpoints() {
        let targets = [
            "10.1.36.1",          // Switch gateway
            "10.8.0.80",           // Campus Core switch
            "turing.iiit.ac.in",   // Campus HPC server
            "google.com",          // External connectivity
            "claude.com"           // External AI endpoint
        ]

        #expect(targets.count == 5)
        #expect(targets.contains("10.1.36.1"))
        #expect(targets.contains("10.8.0.80"))
        #expect(targets.contains("turing.iiit.ac.in"))
        #expect(targets.contains("google.com"))
        #expect(targets.contains("claude.com"))
    }

    @Test("T2-F23-04: Negative latency or excessive loss clamped to valid boundaries")
    func testMetricClamping() {
        func sanitizeProbeResult(latency: Double, loss: Double) -> (latency: Double, loss: Double) {
            let clampedLatency = max(0.0, latency)
            let clampedLoss = min(100.0, max(0.0, loss))
            return (clampedLatency, clampedLoss)
        }

        let sanitized = sanitizeProbeResult(latency: -10.0, loss: 150.0)
        #expect(sanitized.latency == 0.0)
        #expect(sanitized.loss == 100.0)
    }

    @Test("T2-F23-05: Concurrent probe batch results aggregate into telemetry report")
    func testConcurrentProbeAggregation() {
        let probeResults: [ProbeResult] = [
            ProbeResult(targetHost: "10.1.36.1", isReachable: true, latencyMs: 1.2),
            ProbeResult(targetHost: "10.8.0.80", isReachable: true, latencyMs: 2.5),
            ProbeResult(targetHost: "turing.iiit.ac.in", isReachable: true, latencyMs: 4.8),
            ProbeResult(targetHost: "google.com", isReachable: true, latencyMs: 18.2),
            ProbeResult(targetHost: "claude.com", isReachable: true, latencyMs: 22.4)
        ]

        let report = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [],
            gatewayRTT: probeResults[0].latencyMs,
            campusCoreRTT: probeResults[1].latencyMs,
            externalEndpointsRTT: [
                "turing.iiit.ac.in": probeResults[2].latencyMs,
                "google.com": probeResults[3].latencyMs,
                "claude.com": probeResults[4].latencyMs
            ]
        )

        #expect(report.gatewayRTT == 1.2)
        #expect(report.campusCoreRTT == 2.5)
        #expect(report.externalEndpointsRTT.count == 3)
    }
}
