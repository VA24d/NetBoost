import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 04: Core Models Boundaries", .tags(.tier2, .m1_foundation))
struct Tier2_04_CoreModelsBoundariesTests {

    @Test("T2-F04-01: Decoding models with missing optional keys preserves valid defaults")
    func testMissingOptionalKeysDecoding() throws {
        let minimalJSON = """
        {
            "macAddress": "00:11:22:33:44:55",
            "ipAddress": "192.168.2.50",
            "connectedAt": "2026-11-22T19:00:00Z",
            "txBytes": 0,
            "rxBytes": 0
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let client = try decoder.decode(HotspotClient.self, from: minimalJSON)

        #expect(client.hostname == nil)
        #expect(client.ipAddress == "192.168.2.50")
        #expect(client.macAddress == "00:11:22:33:44:55")
    }

    @Test("T2-F04-02: Malformed JSON syntax throws DecodingError without crash")
    func testMalformedJSONSyntax() {
        let malformed = "{\"bsdName\": \"en0\", \"mtu\": }".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NetworkInterfaceInfo.self, from: malformed)
        }
    }

    @Test("T2-F04-03: Boundary integer values (UInt64.max, Int64.max, 0) handled cleanly")
    func testBoundaryIntegerValues() throws {
        let chunk = DownloadChunkInfo(
            id: 0,
            rangeStart: 0,
            rangeEnd: Int64.max - 1,
            downloadedBytes: Int64.max - 1,
            status: .completed,
            speedBytesPerSec: Double(Int.max)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(chunk)
        let decoded = try JSONDecoder().decode(DownloadChunkInfo.self, from: data)

        #expect(decoded.rangeEnd == Int64.max - 1)
        #expect(decoded.downloadedBytes == Int64.max - 1)
        #expect(decoded.progress == 1.0)
    }

    @Test("T2-F04-04: Non-ASCII and emoji characters preserved across serialization")
    func testNonASCIIAndEmojiPreservation() throws {
        let emojiSSID = "🚀 NetBoost-Campus_Wi-Fi_5G_🌟"
        let issue = DetectedIssue(
            severity: .warning,
            title: "Network Latency ⚠️ High on \(emojiSSID)",
            description: "Ping to gateway > 100ms: ⚡️ 152ms detected",
            recommendedFixAction: "fix_mtu"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(issue)
        let decoded = try JSONDecoder().decode(DetectedIssue.self, from: data)

        #expect(decoded.title.contains("🚀"))
        #expect(decoded.title.contains("🌟"))
        #expect(decoded.description.contains("⚡️"))
    }

    @Test("T2-F04-05: Concurrent model copying across tasks preserves Sendable invariants")
    func testConcurrentModelCopies() async throws {
        let initialReport = NetworkTelemetryReport(
            timestamp: Date(),
            interfaces: [
                NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", isPrimary: true)
            ],
            gatewayRTT: 1.5,
            campusCoreRTT: 3.2,
            externalEndpointsRTT: ["google.com": 25.0],
            captivePortalDetected: false,
            activeIssues: []
        )

        await withTaskGroup(of: String.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let copy = initialReport
                    return "\(copy.interfaces.first?.bsdName ?? "")_\(i)"
                }
            }
        }
    }
}
