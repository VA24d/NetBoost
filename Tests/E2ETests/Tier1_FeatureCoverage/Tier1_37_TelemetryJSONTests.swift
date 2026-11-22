import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 37: Telemetry & Diagnostics JSON Exporter", .tags(.tier1, .m5_doctor, .llm_bridge))
struct Tier1_37_TelemetryJSONTests {

    struct TelemetryExporter {
        static func exportJSON(report: NetworkTelemetryReport, pretty: Bool = false) throws -> String {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if pretty {
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            } else {
                encoder.outputFormatting = [.sortedKeys]
            }
            let data = try encoder.encode(report)
            guard let json = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return json
        }
    }

    @Test("T1-F37-01: Serialize NetworkTelemetryReport into valid JSON string")
    func testSerializeTelemetryReport() throws {
        let report = NetworkTelemetryReport(
            interfaces: [NetworkInterfaceInfo(bsdName: "en10", displayName: "Ethernet")],
            gatewayRTT: 0.95,
            captivePortalDetected: false
        )

        let json = try TelemetryExporter.exportJSON(report: report)
        #expect(!json.isEmpty)
        #expect(json.contains("\"gatewayRTT\":0.95"))
    }

    @Test("T1-F37-02: Include interfaces, gateway RTT, campus core RTT, and external RTTs")
    func testTelemetryRequiredFields() throws {
        let report = NetworkTelemetryReport(
            interfaces: [NetworkInterfaceInfo(bsdName: "en10", displayName: "Ethernet", mtu: 1500)],
            gatewayRTT: 1.05,
            campusCoreRTT: 1.35,
            externalEndpointsRTT: [
                "google.com": 18.2,
                "turing.iiit.ac.in": 1.4
            ]
        )

        let json = try TelemetryExporter.exportJSON(report: report)
        #expect(json.contains("gatewayRTT"))
        #expect(json.contains("campusCoreRTT"))
        #expect(json.contains("externalEndpointsRTT"))
        #expect(json.contains("turing.iiit.ac.in"))
    }

    @Test("T1-F37-03: Include detected issues with severity and recommended action")
    func testTelemetryActiveIssues() throws {
        let issue = DetectedIssue(
            severity: .warning,
            title: "Suboptimal MTU",
            description: "MTU 1500 on cellular hotspot",
            recommendedFixAction: "networksetup -setMTU Wi-Fi 1280"
        )
        let report = NetworkTelemetryReport(activeIssues: [issue])

        let json = try TelemetryExporter.exportJSON(report: report)
        #expect(json.contains("\"severity\":\"warning\""))
        #expect(json.contains("\"title\":\"Suboptimal MTU\""))
        #expect(json.contains("1280"))
    }

    @Test("T1-F37-04: Roundtrip decode validates strict conformance to Codable schema")
    func testTelemetryRoundtripDecode() throws {
        let original = NetworkTelemetryReport(
            interfaces: [NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", mtu: 1280)],
            gatewayRTT: 15.0,
            captivePortalStatus: .notDetected
        )

        let json = try TelemetryExporter.exportJSON(report: original)
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NetworkTelemetryReport.self, from: data)

        #expect(decoded.interfaces.first?.bsdName == "en0")
        #expect(decoded.gatewayRTT == 15.0)
        #expect(decoded.captivePortalStatus == .notDetected)
    }

    @Test("T1-F37-05: Pretty-printed JSON output formatted with indentation")
    func testPrettyPrintedJSONOutput() throws {
        let report = NetworkTelemetryReport(gatewayRTT: 2.5)
        let prettyJSON = try TelemetryExporter.exportJSON(report: report, pretty: true)

        #expect(prettyJSON.contains("\n"))
        #expect(prettyJSON.contains("  "))
    }
}
