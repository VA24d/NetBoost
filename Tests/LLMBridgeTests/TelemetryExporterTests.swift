import Testing
import Foundation
@testable import NetBoostCore

@Suite("AI Doctor Bridge: TelemetryExporter Unit & Integration Tests")
struct TelemetryExporterTests {

    @Test("Serialize NetworkTelemetryReport to valid JSON string")
    func testSerializeTelemetryReport() throws {
        let report = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [
                NetworkInterfaceInfo(bsdName: "en10", displayName: "USB 10/100 LAN", mtu: 1500, isPrimary: true)
            ],
            gatewayRTT: 0.95,
            campusCoreRTT: 1.25,
            externalEndpointsRTT: [
                "google.com": 18.2,
                "turing.iiit.ac.in": 1.45
            ],
            captivePortalDetected: false,
            captivePortalStatus: .notDetected,
            activeIssues: [
                DetectedIssue(
                    severity: .warning,
                    title: "Cellular MTU Invariant",
                    description: "MTU 1500 on cellular uplink",
                    recommendedFixAction: "networksetup -setMTU Wi-Fi 1280",
                    automatedFixAvailable: true
                )
            ]
        )

        let json = try TelemetryExporter.exportJSON(report: report, pretty: true)
        #expect(!json.isEmpty)
        #expect(json.contains("\"gatewayRTT\" : 0.95"))
        #expect(json.contains("\"campusCoreRTT\" : 1.25"))
        #expect(json.contains("turing.iiit.ac.in"))
        #expect(json.contains("Cellular MTU Invariant"))
    }

    @Test("Roundtrip JSON decode perfectly restores report data")
    func testRoundtripDecode() throws {
        let original = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [
                NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", mtu: 1280, isPrimary: true)
            ],
            gatewayRTT: 12.5,
            campusCoreRTT: 14.8,
            externalEndpointsRTT: ["claude.com": 22.4],
            captivePortalDetected: false,
            captivePortalStatus: .notDetected,
            activeIssues: []
        )

        let json = try TelemetryExporter.exportJSON(report: original)
        let decoded = try TelemetryExporter.importJSON(json)

        #expect(decoded.interfaces.first?.bsdName == "en0")
        #expect(decoded.interfaces.first?.mtu == 1280)
        #expect(decoded.gatewayRTT == 12.5)
        #expect(decoded.campusCoreRTT == 14.8)
        #expect(decoded.externalEndpointsRTT["claude.com"] == 22.4)
        #expect(decoded.captivePortalDetected == false)
    }

    @Test("sample_telemetry.json fixture decodes cleanly against NetworkTelemetryReport schema")
    func testSampleTelemetryFixture() throws {
        let fixturePath = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/Telemetry/sample_telemetry.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let jsonStr = String(data: data, encoding: .utf8)!

        let report = try TelemetryExporter.importJSON(jsonStr)

        #expect(report.interfaces.count == 2)
        #expect(report.interfaces.first?.bsdName == "en10")
        #expect(report.gatewayRTT == 0.82)
        #expect(report.campusCoreRTT == 1.74)
        #expect(report.externalEndpointsRTT["turing.iiit.ac.in"] == 1.65)
        #expect(report.captivePortalDetected == false)
        #expect(report.activeIssues.count == 1)
        #expect(report.activeIssues.first?.severity == .warning)
    }
}
