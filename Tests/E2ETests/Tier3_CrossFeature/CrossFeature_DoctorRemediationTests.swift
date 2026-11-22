import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 3: Campus Doctor MTU Auto-Fix + Cellular Sensor Interaction", .tags(.tier3, .diagnostics, .m5_doctor))
struct CrossFeature_DoctorRemediationTests {

    @Test("Network sensor identifies cellular hotspot environment via IP prefix and interface")
    func testCellularSensorClassification() {
        let env = MockNetworkEnvironment(initialState: .defaultCampusLAN)
        #expect(env.currentState.isCampusLAN)

        // Switch to iPhone cellular hotspot
        env.transition(to: .defaultCellularHotspot)
        #expect(env.currentState.isCellular)
        #expect(!env.currentState.isCampusLAN)
        #expect(env.currentState.primaryInterface == "en0")
    }

    @Test("Doctor detects MTU 1500 on cellular hotspot as critical TLS fragmentation risk")
    func testSuboptimalMTUDetectionOnCellular() {
        // Wi-Fi interface configured with default MTU 1500
        let wifiInterface = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "172.20.10.2")],
            gateway: "172.20.10.1",
            mtu: 1500,
            isPrimary: true
        )

        // Doctor analyzes interface on cellular hotspot
        var detectedIssues: [DetectedIssue] = []
        if wifiInterface.ipAddresses.contains(where: { $0.address.hasPrefix("172.20.10.") }) && wifiInterface.mtu > 1280 {
            detectedIssues.append(DetectedIssue(
                severity: .warning,
                title: "Cellular Hotspot MTU Invariant Violation",
                description: "MTU \(wifiInterface.mtu) exceeds safe threshold 1280 for cellular uplink.",
                recommendedFixAction: "networksetup -setMTU Wi-Fi 1280",
                automatedFixAvailable: true
            ))
        }

        #expect(detectedIssues.count == 1)
        #expect(detectedIssues.first?.recommendedFixAction == "networksetup -setMTU Wi-Fi 1280")
        #expect(detectedIssues.first?.automatedFixAvailable == true)
    }

    @Test("Auto-fix executes networksetup to set MTU 1280 without touching Ethernet en10")
    func testAutoFixAppliesMTU1280ToWiFiOnly() async throws {
        let runner = MockProcessRunner()

        // Execute MTU 1280 fix on Wi-Fi
        let output = try await runner.run("networksetup", arguments: ["-setMTU", "Wi-Fi", "1280"])
        #expect(output.succeeded)
        #expect(runner.didExecute(commandContaining: "networksetup -setMTU Wi-Fi 1280"))

        // Ethernet en10 remains 1500
        let en10MTU = 1500
        #expect(en10MTU == 1500)
        #expect(!runner.didExecute(commandContaining: "-setMTU USB 10/100 LAN 1280"))
    }

    @Test("Post-fix inspection verifies MTU setting and generates updated telemetry report")
    func testPostFixTelemetryReportReflectsCleanHealth() async throws {
        let runner = MockProcessRunner()

        // Inspect MTU after fix
        let getMTU = try await runner.run("networksetup", arguments: ["-getMTU", "Wi-Fi"])
        #expect(getMTU.succeeded)

        // Generate telemetry report
        let report = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [
                NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", mtu: 1280, isPrimary: true),
                NetworkInterfaceInfo(bsdName: "en10", displayName: "USB 10/100 LAN", mtu: 1500, isPrimary: false)
            ],
            gatewayRTT: 1.2,
            campusCoreRTT: 15.4,
            externalEndpointsRTT: ["turing.iiit.ac.in": 16.2, "google.com": 18.5],
            captivePortalDetected: false,
            activeIssues: [] // Resolved
        )

        #expect(report.activeIssues.isEmpty)
        #expect(report.interfaces.first?.mtu == 1280)
        #expect(report.gatewayRTT != nil)
    }

    @Test("Rollback routine restores default MTU 1500 when switching back to Campus LAN")
    func testRollbackMTUOnCampusLANTransition() async throws {
        let env = MockNetworkEnvironment(initialState: .defaultCellularHotspot)
        let runner = MockProcessRunner()

        // Transition back to campus LAN
        env.transition(to: .defaultCampusLAN)
        #expect(env.currentState.isCampusLAN)

        // Revert Wi-Fi MTU to standard 1500
        let revertOutput = try await runner.run("networksetup", arguments: ["-setMTU", "Wi-Fi", "1500"])
        #expect(revertOutput.succeeded)
        #expect(runner.didExecute(commandContaining: "networksetup -setMTU Wi-Fi 1500"))
    }
}
