import Foundation
import Testing
@testable import NetBoostCore

@Suite("Hotspot 802.1X Detection & Upstream Selection Tests")
struct Hotspot8021XDetectionTests {

    @Test("parseActive8021XInterfaces extracts eapolclient interfaces accurately and ignores noise")
    func testParseActive8021XInterfaces() {
        let psOutput = """
          1 /sbin/launchd
        363 /usr/libexec/configd
        812 /System/Library/SystemConfiguration/EAPOLController.bundle/Contents/Resources/eapolclient -i en10 -u 501 -g 20
        945 eapolclient -ien9 -u 501 -g 20
        999 /usr/bin/python3 -c print('eapolclient -i en7')
        1024 /usr/libexec/eapolclient -i en0
        """

        let parsed = HotspotNATController.parseActive8021XInterfaces(psOutput: psOutput)
        #expect(parsed == Set(["en10", "en9", "en0"]))
        #expect(!parsed.contains("en7"))
        #expect(!parsed.contains("501"))
        #expect(!parsed.contains("20"))

        let processes = HotspotNATController.parseEAPOLClientProcesses(psOutput: psOutput)
        #expect(processes.count == 3)
        #expect(processes.contains { $0.pid == 812 && $0.interface == "en10" })
        #expect(processes.contains { $0.pid == 945 && $0.interface == "en9" })
        #expect(processes.contains { $0.pid == 1024 && $0.interface == "en0" })
    }

    @Test("selectPreferredUpstreamInterface skips 802.1X-protected adapters when a clean wired/USB adapter exists")
    func testSelectPreferredUpstreamInterface() {
        let en0 = NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", ipAddresses: [IPAddress(address: "192.168.1.5")], isUp: true)
        let en10 = NetworkInterfaceInfo(bsdName: "en10", displayName: "USB 10/100 LAN", ipAddresses: [IPAddress(address: "10.1.36.52")], isPrimary: true, isUp: true)
        let en9 = NetworkInterfaceInfo(bsdName: "en9", displayName: "iPhone USB", ipAddresses: [IPAddress(address: "172.20.10.2")], isUp: true)
        let utun4 = NetworkInterfaceInfo(bsdName: "utun4", displayName: "VPN Tunnel", ipAddresses: [IPAddress(address: "10.8.0.2")], isUp: true)
        let bridge100 = NetworkInterfaceInfo(bsdName: "bridge100", displayName: "Bridge", ipAddresses: [IPAddress(address: "192.168.2.1")], isUp: true)

        let all = [en0, utun4, bridge100, en10, en9]
        let downEn9 = NetworkInterfaceInfo(bsdName: "en9", displayName: "iPhone USB", ipAddresses: [IPAddress(address: "172.20.10.2")], isUp: false)

        #expect(HotspotNATController.selectPreferredUpstreamInterface(from: all, dot1XProtected: []) == "en10")
        #expect(HotspotNATController.selectPreferredUpstreamInterface(from: all, dot1XProtected: ["en10"]) == "en9")
        #expect(HotspotNATController.selectPreferredUpstreamInterface(from: [en0, en10, downEn9], dot1XProtected: ["en10"]) == "en10")
        #expect(HotspotNATController.selectPreferredUpstreamInterface(from: all, dot1XProtected: ["en10", "en9"]) == "en10")
        #expect(HotspotNATController.selectPreferredUpstreamInterface(from: [en0, utun4, bridge100], dot1XProtected: []) == nil)
    }

    @Test("HotspotNATController.startHotspot rejects 802.1X-protected upstream immediately without mutating state")
    func testStartHotspotFailsFastOn8021XUpstream() async {
        let controller = HotspotNATController(
            configuration: .default,
            active8021XProvider: { ["en10"] }
        )

        do {
            try await controller.startHotspot(upstreamInterface: "en10", downstreamInterface: "en0")
            Issue.record("Expected startHotspot to throw when upstream has active 802.1X")
        } catch let error as PrivilegeError {
            guard case .executionFailed(let message) = error else {
                Issue.record("Expected executionFailed error, got \(error)")
                return
            }
            #expect(message.contains("802.1X"))
            #expect(message.contains("en10"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(!controller.isActive)
        #expect(controller.configuration.upstreamInterface == "en10")
    }
}
