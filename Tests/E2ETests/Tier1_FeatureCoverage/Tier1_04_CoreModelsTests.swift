import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 04: Core Data Models & Codable Schemas", .tags(.tier1, .m1_foundation))
struct Tier1_04_CoreModelsTests {

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    @Test("T1-F04-01: NetworkInterfaceInfo & IPAddress JSON roundtrip serialization")
    func testNetworkInterfaceInfoSerialization() throws {
        let ips = [
            IPAddress(address: "10.1.36.52", version: .v4, netmask: "255.255.252.0", prefixLength: 22),
            IPAddress(address: "fe80::1", version: .v6, prefixLength: 64)
        ]
        let original = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "USB 10/100 LAN",
            ipAddresses: ips,
            macAddress: "00:e0:4c:68:01:aa",
            gateway: "10.1.36.1",
            mtu: 1500,
            isPrimary: true,
            isUp: true
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(NetworkInterfaceInfo.self, from: data)

        #expect(decoded == original)
        #expect(decoded.ipv4Address == "10.1.36.52")
        #expect(decoded.ipv6Address == "fe80::1")
    }

    @Test("T1-F04-02: HotspotConfiguration & HotspotClient JSON roundtrip serialization")
    func testHotspotModelsSerialization() throws {
        let config = HotspotConfiguration(
            subnet: "192.168.2.0/24",
            gateway: "192.168.2.1",
            dhcpRangeStart: "192.168.2.10",
            dhcpRangeEnd: "192.168.2.100",
            interfaceName: "en0",
            upstreamInterface: "en10",
            isActive: true
        )

        let configData = try encoder.encode(config)
        let decodedConfig = try decoder.decode(HotspotConfiguration.self, from: configData)
        #expect(decodedConfig == config)

        let client = HotspotClient(
            macAddress: "aa:bb:cc:dd:ee:ff",
            ipAddress: "192.168.2.15",
            hostname: "iPad-Pro",
            txBytes: 1048576,
            rxBytes: 2097152
        )
        let clientData = try encoder.encode(client)
        let decodedClient = try decoder.decode(HotspotClient.self, from: clientData)
        #expect(decodedClient.macAddress == client.macAddress)
        #expect(decodedClient.ipAddress == client.ipAddress)
        #expect(decodedClient.hostname == "iPad-Pro")
    }

    @Test("T1-F04-03: VPNProfileInfo & VPNRouteEntry JSON roundtrip serialization")
    func testVPNModelsSerialization() throws {
        let routes = [
            VPNRouteEntry(destinationSubnet: "10.1.0.0", mask: "255.255.0.0", gateway: "10.1.36.1"),
            VPNRouteEntry(destinationSubnet: "10.8.0.0", mask: "255.255.0.0")
        ]
        let original = VPNProfileInfo(
            name: "macos.vpn",
            serverAddress: "vpn2.iiit.ac.in",
            proto: "udp",
            port: 1194,
            cipher: "AES-128-GCM",
            routes: routes,
            dnsServers: ["10.4.20.21", "10.4.20.222"],
            isCampusSplit: true,
            filePath: "/path/to/macos.vpn"
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(VPNProfileInfo.self, from: data)

        #expect(decoded == original)
        #expect(decoded.routes.count == 2)
        #expect(decoded.dnsServers.contains("10.4.20.21"))
    }

    @Test("T1-F04-04: DownloadTaskInfo & DownloadChunkInfo JSON roundtrip serialization")
    func testDownloadModelsSerialization() throws {
        let chunks = [
            DownloadChunkInfo(id: 0, rangeStart: 0, rangeEnd: 524287, downloadedBytes: 524288, status: .completed, speedBytesPerSec: 1048576),
            DownloadChunkInfo(id: 1, rangeStart: 524288, rangeEnd: 1048575, downloadedBytes: 262144, status: .downloading, speedBytesPerSec: 524288)
        ]
        let original = DownloadTaskInfo(
            id: UUID(),
            url: URL(string: "https://example.com/dataset.iso")!,
            destinationURL: URL(fileURLWithPath: "/tmp/dataset.iso"),
            totalBytes: 1048576,
            downloadedBytes: 786432,
            chunks: chunks,
            status: .downloading,
            speedBytesPerSec: 1572864,
            etaSeconds: 0.16,
            checksum: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(DownloadTaskInfo.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.url == original.url)
        #expect(decoded.chunks.count == 2)
        #expect(decoded.progress > 0.7)
    }

    @Test("T1-F04-05: NetworkTelemetryReport & ProbeResult JSON roundtrip serialization")
    func testDiagnosticModelsSerialization() throws {
        let probe = ProbeResult(
            targetHost: "turing.iiit.ac.in",
            targetIP: "10.8.0.80",
            isReachable: true,
            latencyMs: 1.45,
            packetLossPercent: 0.0
        )
        let issue = DetectedIssue(
            severity: .warning,
            title: "MTU Suboptimal",
            description: "Wi-Fi MTU is 1500 on cellular hotspot",
            recommendedFixAction: "Set MTU to 1280"
        )
        let original = NetworkTelemetryReport(
            interfaces: [NetworkInterfaceInfo(bsdName: "en10", displayName: "Ethernet")],
            gatewayRTT: 0.85,
            campusCoreRTT: 1.12,
            externalEndpointsRTT: ["google.com": 18.5, "turing.iiit.ac.in": 1.45],
            captivePortalDetected: false,
            captivePortalStatus: .notDetected,
            activeIssues: [issue]
        )

        let probeData = try encoder.encode(probe)
        let decodedProbe = try decoder.decode(ProbeResult.self, from: probeData)
        #expect(decodedProbe.targetHost == probe.targetHost)
        #expect(decodedProbe.latencyMs == probe.latencyMs)

        let reportData = try encoder.encode(original)
        let decodedReport = try decoder.decode(NetworkTelemetryReport.self, from: reportData)
        #expect(decodedReport.externalEndpointsRTT["google.com"] == 18.5)
        #expect(decodedReport.activeIssues.count == 1)
        #expect(decodedReport.activeIssues.first?.severity == .warning)
    }
}
