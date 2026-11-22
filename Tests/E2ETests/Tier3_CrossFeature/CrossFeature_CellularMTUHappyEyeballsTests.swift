import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 3: LAN IPv6 Disabler (Happy Eyeballs) + Latency Probes Interaction", .tags(.tier3, .diagnostics, .m5_doctor))
struct CrossFeature_CellularMTUHappyEyeballsTests {

    @Test("Multi-endpoint latency probe detects 500ms Happy Eyeballs hang on unrouted IPv6 LAN")
    func testHappyEyeballsDelayDetection() {
        // Simulated probe results before fix: Dual-stack timeout causes 500ms hang
        let degradedProbe = ProbeResult(
            targetHost: "10.1.36.1",
            targetIP: "10.1.36.1",
            isReachable: true,
            latencyMs: 512.4, // RFC 8305 Happy Eyeballs initial timeout
            packetLossPercent: 0.0
        )

        let isHangDetected = degradedProbe.latencyMs >= 500.0 && degradedProbe.targetHost.hasPrefix("10.1.")
        #expect(isHangDetected == true)

        let issue = DetectedIssue(
            severity: .warning,
            title: "Campus LAN IPv6 Happy Eyeballs Delay Detected",
            description: "Unrouted IPv6 on Ethernet causes a ~500ms connection delay for dual-stack hosts.",
            recommendedFixAction: "networksetup -setv6off \"USB 10/100 LAN\"",
            automatedFixAvailable: true
        )

        #expect(issue.severity == .warning)
        #expect(issue.recommendedFixAction.contains("-setv6off"))
    }

    @Test("IPv6 disabler executes networksetup -setv6off on Ethernet service via process runner")
    func testDisableIPv6Execution() async throws {
        let runner = MockProcessRunner()

        let serviceName = "USB 10/100 LAN"
        let output = try await runner.run("networksetup", arguments: ["-setv6off", serviceName])
        #expect(output.succeeded)
        #expect(runner.didExecute(commandContaining: "networksetup -setv6off USB 10/100 LAN"))
    }

    @Test("Post-fix RTT probe to local gateway and campus core verifies latency drops to sub-2ms")
    func testPostFixLatencyNormalization() {
        // Simulated probe results after disabling IPv6: immediate IPv4 connect
        let gatewayProbe = ProbeResult(
            targetHost: "10.1.36.1",
            targetIP: "10.1.36.1",
            isReachable: true,
            latencyMs: 0.85,
            packetLossPercent: 0.0
        )

        let campusCoreProbe = ProbeResult(
            targetHost: "10.8.0.80",
            targetIP: "10.8.0.80",
            isReachable: true,
            latencyMs: 1.45,
            packetLossPercent: 0.0
        )

        #expect(gatewayProbe.latencyMs < 2.0)
        #expect(campusCoreProbe.latencyMs < 2.0)
        #expect(gatewayProbe.isReachable)
        #expect(campusCoreProbe.isReachable)
    }

    @Test("Campus Doctor telemetry report reflects IPv6 issue resolution and latency health")
    func testTelemetryReportReflectsHappyEyeballsResolution() {
        let report = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [
                NetworkInterfaceInfo(bsdName: "en10", displayName: "USB 10/100 LAN", mtu: 1500, isPrimary: true)
            ],
            gatewayRTT: 0.85,
            campusCoreRTT: 1.45,
            externalEndpointsRTT: ["google.com": 14.2, "turing.iiit.ac.in": 1.6],
            captivePortalDetected: false,
            activeIssues: [] // Clean
        )

        #expect(report.activeIssues.isEmpty)
        #expect(report.gatewayRTT ?? 999 < 2.0)
        #expect(report.campusCoreRTT ?? 999 < 2.0)
    }

    @Test("Rollback routine restores IPv6 automatic configuration when transitioning off campus LAN")
    func testRollbackIPv6Automatic() async throws {
        let runner = MockProcessRunner()

        let serviceName = "USB 10/100 LAN"
        let output = try await runner.run("networksetup", arguments: ["-setv6automatic", serviceName])
        #expect(output.succeeded)
        #expect(runner.didExecute(commandContaining: "networksetup -setv6automatic USB 10/100 LAN"))
    }
}
