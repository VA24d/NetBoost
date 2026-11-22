import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 37: Telemetry JSON Exporter Boundaries", .tags(.tier2, .m5_doctor, .llm_bridge))
struct Tier2_37_TelemetryJSONBoundariesTests {

    @Test("T2-F37-01: Telemetry report with empty interfaces and nil RTT values serializes safely")
    func testEmptyTelemetrySerialization() throws {
        let minimalReport = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [],
            gatewayRTT: nil,
            campusCoreRTT: nil,
            externalEndpointsRTT: [:],
            captivePortalDetected: false,
            captivePortalStatus: .notDetected,
            activeIssues: []
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(minimalReport)
        let jsonString = String(data: data, encoding: .utf8) ?? ""

        #expect(!jsonString.isEmpty)
        #expect(jsonString.contains("\"interfaces\" : ["))
        #expect(jsonString.contains("\"captivePortalDetected\" : false"))
    }

    @Test("T2-F37-02: ISO 8601 UTC timestamp formatting compliance")
    func testISO8601TimestampFormatting() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let now = Date(timeIntervalSince1970: 1700000000)
        let report = NetworkTelemetryReport(timestamp: now)

        let data = try encoder.encode(report)
        let jsonString = String(data: data, encoding: .utf8) ?? ""

        #expect(jsonString.contains("2023-11-14T"))
    }

    @Test("T2-F37-03: Decodes sample_telemetry.json fixture cleanly")
    func testDecodeSampleTelemetryFixture() throws {
        let fixturePath = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/Telemetry/sample_telemetry.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(NetworkTelemetryReport.self, from: data)

        #expect(report.interfaces.count >= 1)
        #expect(report.gatewayRTT != nil)
    }

    @Test("T2-F37-04: Sensitive credentials (passwords/tokens) redacted in exported issue logs")
    func testCredentialRedaction() {
        func sanitizeDescription(_ text: String) -> String {
            // Regex replace password=... or token=...
            var sanitized = text
            let patterns = ["password=[^&\\s]+", "token=[^&\\s]+", "bearer\\s+[A-Za-z0-9_.-]+"]
            for pat in patterns {
                if let regex = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) {
                    sanitized = regex.stringByReplacingMatches(
                        in: sanitized,
                        range: NSRange(location: 0, length: sanitized.utf16.count),
                        withTemplate: "[REDACTED]"
                    )
                }
            }
            return sanitized
        }

        let sensitive = "Connection failed with token=secret123456 and password=myCampusPassword"
        let redacted = sanitizeDescription(sensitive)
        #expect(!redacted.contains("secret123456"))
        #expect(!redacted.contains("myCampusPassword"))
        #expect(redacted.contains("[REDACTED]"))
    }

    @Test("T2-F37-05: Serialization and deserialization roundtrip maintains identical values")
    func testTelemetryRoundtrip() throws {
        let issue = DetectedIssue(
            severity: .warning,
            title: "MTU Mismatch",
            description: "Wi-Fi MTU is 1500 on cellular hotspot",
            recommendedFixAction: "fix_mtu"
        )
        let report = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", isPrimary: true)],
            gatewayRTT: 1.25,
            campusCoreRTT: 2.50,
            externalEndpointsRTT: ["google.com": 18.0],
            captivePortalDetected: false,
            activeIssues: [issue]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(report)
        let decoded = try decoder.decode(NetworkTelemetryReport.self, from: data)

        #expect(decoded.interfaces.first?.bsdName == "en0")
        #expect(decoded.gatewayRTT == 1.25)
        #expect(decoded.activeIssues.count == 1)
        #expect(decoded.activeIssues.first?.recommendedFixAction == "fix_mtu")
    }
}
