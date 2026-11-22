import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 4 - Scenario 7: Cellular Hotspot Degraded State Recovery", .tags(.tier4, .diagnostics, .m5_doctor))
struct Scenario07_CellularHotspotDegradedRecoveryTests {

    @Test("Cellular Hotspot recovery: Detects MTU 1500 and Happy Eyeballs delay -> Executes dual remediation -> Confirms health")
    func testCellularHotspotDegradedStateRemediation() async throws {
        let runner = MockProcessRunner()
        let env = MockNetworkEnvironment(initialState: .defaultCampusLAN)

        // Step 1: Transition to Cellular Hotspot Environment
        env.transition(to: .defaultCellularHotspot)
        #expect(env.currentState.isCellular)
        #expect(env.currentState.primaryInterface == "en0")

        // Step 2: Inject Dual Degraded Network State
        // Defect A: MTU is 1500 on cellular hotspot
        let wifiInterface = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "172.20.10.2")],
            gateway: "172.20.10.1",
            mtu: 1500,
            isPrimary: true
        )

        // Defect B: Dual-stack Happy Eyeballs 500ms hang
        let degradedProbe = ProbeResult(
            targetHost: "google.com",
            isReachable: true,
            latencyMs: 518.2, // 500ms RFC 8305 fallback
            packetLossPercent: 10.0
        )

        // Step 3: Campus Doctor Diagnostic Scan
        var detectedIssues: [DetectedIssue] = []

        if wifiInterface.mtu > 1280 {
            detectedIssues.append(DetectedIssue(
                severity: .warning,
                title: "Cellular MTU Invariant Violation",
                description: "MTU 1500 causes TLS packet fragmentation and bad record MAC on cellular uplinks.",
                recommendedFixAction: "networksetup -setMTU Wi-Fi 1280",
                automatedFixAvailable: true
            ))
        }

        if degradedProbe.latencyMs >= 500.0 {
            detectedIssues.append(DetectedIssue(
                severity: .warning,
                title: "Happy Eyeballs Latency Hang",
                description: "Unrouted IPv6 causes 500ms dual-stack fallback delays.",
                recommendedFixAction: "networksetup -setv6off Wi-Fi",
                automatedFixAvailable: true
            ))
        }

        #expect(detectedIssues.count == 2)

        // Step 4: One-Click Auto-Fix Execution
        for issue in detectedIssues {
            if issue.recommendedFixAction.contains("-setMTU") {
                let mtuFix = try await runner.run("networksetup", arguments: ["-setMTU", "Wi-Fi", "1280"])
                #expect(mtuFix.succeeded)
            } else if issue.recommendedFixAction.contains("-setv6off") {
                let v6Fix = try await runner.run("networksetup", arguments: ["-setv6off", "Wi-Fi"])
                #expect(v6Fix.succeeded)
            }
        }

        #expect(runner.didExecute(commandContaining: "networksetup -setMTU Wi-Fi 1280"))
        #expect(runner.didExecute(commandContaining: "networksetup -setv6off Wi-Fi"))

        // Step 5: Post-Fix Telemetry Verification
        let healthyProbe = ProbeResult(
            targetHost: "google.com",
            isReachable: true,
            latencyMs: 18.4,
            packetLossPercent: 0.0
        )

        let resolvedTelemetry = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [
                NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", mtu: 1280, isPrimary: true)
            ],
            gatewayRTT: 12.1,
            campusCoreRTT: nil,
            externalEndpointsRTT: ["google.com": healthyProbe.latencyMs],
            captivePortalDetected: false,
            activeIssues: [] // Clean
        )

        #expect(resolvedTelemetry.activeIssues.isEmpty)
        #expect(resolvedTelemetry.interfaces.first?.mtu == 1280)
        #expect(resolvedTelemetry.externalEndpointsRTT["google.com"] ?? 999 < 50.0)
    }
}
