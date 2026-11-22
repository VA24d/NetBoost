import Foundation
import Testing
@testable import NetBoostCore

@Suite("Core Data Models Roundtrip Serialization Tests")
struct ModelTests {

    private func roundtrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    @Test("InterfaceModels: NetworkInterfaceInfo & IPAddress JSON roundtrip")
    func testInterfaceModelsRoundtrip() throws {
        let ipv4 = IPAddress(address: "10.1.36.52", version: .v4, netmask: "255.255.252.0", prefixLength: 22)
        let ipv6 = IPAddress(address: "fe80::1", version: .v6, prefixLength: 64)

        let original = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "USB 10/100 LAN",
            ipAddresses: [ipv4, ipv6],
            macAddress: "00:e0:7f:61:08:7a",
            gateway: "10.1.36.1",
            mtu: 1500,
            isPrimary: true,
            isUp: true
        )

        let decoded = try roundtrip(original)
        #expect(decoded == original)
        #expect(decoded.bsdName == "en10")
        #expect(decoded.ipv4Address == "10.1.36.52")
        #expect(decoded.ipv6Address == "fe80::1")
        #expect(decoded.mtu == 1500)
        #expect(decoded.isPrimary == true)
        #expect(decoded.id == "en10")
    }

    @Test("HotspotModels: HotspotClient, DHCPLease, and HotspotConfiguration JSON roundtrip")
    func testHotspotModelsRoundtrip() throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let client = HotspotClient(
            macAddress: "2a:c1:a0:1e:ad:64",
            ipAddress: "192.168.2.15",
            hostname: "iPhone-User",
            connectedAt: now,
            txBytes: 1048576,
            rxBytes: 5242880
        )
        let decodedClient = try roundtrip(client)
        #expect(decodedClient == client)
        #expect(decodedClient.id == "2a:c1:a0:1e:ad:64")
        #expect(decodedClient.txBytes == 1048576)

        let lease = DHCPLease(
            ipAddress: "192.168.2.20",
            macAddress: "00:11:22:33:44:55",
            leaseStart: now,
            leaseDuration: 3600
        )
        let decodedLease = try roundtrip(lease)
        #expect(decodedLease == lease)
        #expect(decodedLease.expiresAt == now.addingTimeInterval(3600))
        #expect(decodedLease.isExpired == true)

        let config = HotspotConfiguration(
            subnet: "192.168.2.0/24",
            gateway: "192.168.2.1",
            dhcpRangeStart: "192.168.2.10",
            dhcpRangeEnd: "192.168.2.100",
            interfaceName: "en0",
            upstreamInterface: "en10",
            isActive: true
        )
        let decodedConfig = try roundtrip(config)
        #expect(decodedConfig == config)
        #expect(decodedConfig.gateway == "192.168.2.1")
        #expect(decodedConfig.isActive == true)
    }

    @Test("VPNModels: VPNProfileInfo, VPNRouteEntry, and VPNStatus JSON roundtrip")
    func testVPNModelsRoundtrip() throws {
        let route1 = VPNRouteEntry(destinationSubnet: "10.4.0.0", mask: "255.255.0.0", gateway: "10.8.0.1")
        let route2 = VPNRouteEntry(destinationSubnet: "10.8.0.0", mask: "255.255.0.0", gateway: "10.8.0.1")

        let profile = VPNProfileInfo(
            name: "macos.ovpn",
            serverAddress: "vpn.iiit.ac.in",
            proto: "udp",
            port: 1194,
            cipher: "AES-256-GCM",
            routes: [route1, route2],
            dnsServers: ["10.4.20.21", "10.4.20.222"],
            isCampusSplit: true,
            filePath: "/Users/va/Downloads/macos.ovpn"
        )

        let decodedProfile = try roundtrip(profile)
        #expect(decodedProfile == profile)
        #expect(decodedProfile.routes.count == 2)
        #expect(decodedProfile.isCampusSplit == true)

        let status = VPNStatus.connected
        let decodedStatus = try roundtrip(status)
        #expect(decodedStatus == .connected)
    }

    @Test("AcceleratorModels: DownloadTaskInfo & DownloadChunkInfo JSON roundtrip")
    func testAcceleratorModelsRoundtrip() throws {
        let chunk1 = DownloadChunkInfo(
            id: 0,
            rangeStart: 0,
            rangeEnd: 1048575,
            downloadedBytes: 1048576,
            status: .completed,
            speedBytesPerSec: 524288
        )
        let chunk2 = DownloadChunkInfo(
            id: 1,
            rangeStart: 1048576,
            rangeEnd: 2097151,
            downloadedBytes: 524288,
            status: .downloading,
            speedBytesPerSec: 262144
        )

        #expect(chunk1.progress == 1.0)
        #expect(chunk2.progress == 0.5)

        let taskId = UUID()
        let task = DownloadTaskInfo(
            id: taskId,
            url: URL(string: "https://example.com/largefile.iso")!,
            destinationURL: URL(fileURLWithPath: "/tmp/largefile.iso"),
            totalBytes: 2097152,
            downloadedBytes: 1572864,
            chunks: [chunk1, chunk2],
            status: .downloading,
            speedBytesPerSec: 786432,
            etaSeconds: 0.67,
            checksum: "a1b2c3d4e5"
        )

        let decodedTask = try roundtrip(task)
        #expect(decodedTask == task)
        #expect(decodedTask.chunks.count == 2)
        #expect(decodedTask.progress == 0.75)
    }

    @Test("DiagnosticModels: NetworkTelemetryReport, ProbeResult, and DetectedIssue JSON roundtrip")
    func testDiagnosticModelsRoundtrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let probeGateway = ProbeResult(
            targetHost: "10.1.36.1",
            targetIP: "10.1.36.1",
            isReachable: true,
            latencyMs: 2.5,
            packetLossPercent: 0.0,
            timestamp: fixedDate
        )
        let probeExternal = ProbeResult(
            targetHost: "google.com",
            targetIP: "142.251.43.46",
            isReachable: true,
            latencyMs: 16.1,
            packetLossPercent: 0.0,
            timestamp: fixedDate
        )

        let issueId = UUID()
        let issue = DetectedIssue(
            id: issueId,
            severity: .warning,
            title: "MTU Mismatch",
            description: "Wi-Fi interface en0 has MTU 1500 which may cause TLS packet drops on hotspot",
            recommendedFixAction: "Reduce MTU to 1280",
            automatedFixAvailable: true
        )

        #expect(IssueSeverity.info < IssueSeverity.warning)
        #expect(IssueSeverity.warning < IssueSeverity.critical)

        let report = NetworkTelemetryReport(
            timestamp: fixedDate,
            interfaces: [],
            gatewayRTT: 2.5,
            campusCoreRTT: 1.2,
            externalEndpointsRTT: ["google.com": 16.1, "claude.com": 33.9],
            captivePortalDetected: false,
            captivePortalStatus: .notDetected,
            activeIssues: [issue]
        )

        let decodedReport = try roundtrip(report)
        #expect(decodedReport == report)
        #expect(decodedReport.externalEndpointsRTT["google.com"] == 16.1)
        #expect(decodedReport.activeIssues.first?.severity == .warning)

        let decodedProbeGateway = try roundtrip(probeGateway)
        #expect(decodedProbeGateway == probeGateway)

        let decodedProbeExternal = try roundtrip(probeExternal)
        #expect(decodedProbeExternal == probeExternal)
    }
}
