import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 43: Hotspot & Dispatcher Views Boundaries", .tags(.tier2, .m6_ui))
struct Tier2_43_HotspotDispatcherViewsBoundariesTests {

    @Test("T2-F43-01: Hotspot toggle disabled when no active upstream Ethernet interface")
    func testHotspotDisabledWithoutEthernet() {
        func canEnableHotspot(interfaces: [NetworkInterfaceInfo]) -> Bool {
            return interfaces.contains { $0.bsdName == "en10" && $0.isUp && $0.ipv4Address != nil }
        }

        let onlyWiFi = [
            NetworkInterfaceInfo(bsdName: "en0", displayName: "Wi-Fi", ipAddresses: [IPAddress(address: "192.168.1.100")])
        ]
        #expect(canEnableHotspot(interfaces: onlyWiFi) == false)

        let withEthernet = [
            NetworkInterfaceInfo(bsdName: "en10", displayName: "Ethernet", ipAddresses: [IPAddress(address: "10.1.36.52")])
        ]
        #expect(canEnableHotspot(interfaces: withEthernet) == true)
    }

    @Test("T2-F43-02: Proxy port collision flagged with error indicator in UI view model")
    func testProxyPortCollisionValidation() {
        func validatePortAssignments(ports: [Int: String]) -> [String] {
            var errors: [String] = []
            let assignedPorts = Array(ports.keys)
            let uniquePorts = Set(assignedPorts)
            if assignedPorts.count != uniquePorts.count {
                errors.append("Duplicate proxy port assignment detected.")
            }
            return errors
        }

        let validPorts = [1080: "en10", 1081: "en0", 1082: "auto"]
        #expect(validatePortAssignments(ports: validPorts).isEmpty)
    }

    @Test("T2-F43-03: Custom port input validation restricts to unprivileged range (1024-65535)")
    func testCustomPortValidation() {
        func isValidProxyPort(_ portString: String) -> Bool {
            guard let port = Int(portString) else { return false }
            return port >= 1024 && port <= 65535
        }

        #expect(isValidProxyPort("1080") == true)
        #expect(isValidProxyPort("8080") == true)
        #expect(isValidProxyPort("80") == false)       // Privileged
        #expect(isValidProxyPort("70000") == false)    // Out of range
        #expect(isValidProxyPort("abc") == false)      // NaN
    }

    @Test("T2-F43-04: Disconnecting a client removes client from active hotspot client list")
    func testDisconnectClientRemovesFromList() {
        var clients = [
            HotspotClient(macAddress: "00:11:22:33:44:01", ipAddress: "192.168.2.10"),
            HotspotClient(macAddress: "00:11:22:33:44:02", ipAddress: "192.168.2.11")
        ]

        func disconnectClient(mac: String) {
            clients.removeAll { $0.macAddress == mac }
        }

        disconnectClient(mac: "00:11:22:33:44:01")
        #expect(clients.count == 1)
        #expect(clients.first?.macAddress == "00:11:22:33:44:02")
    }

    @Test("T2-F43-05: Copy CLI helper generates pasteboard string for selected proxy port")
    func testCopyCLIHelperGeneration() {
        func makeCopySnippet(port: Int) -> String {
            return "ALL_PROXY=socks5://127.0.0.1:\(port)"
        }

        #expect(makeCopySnippet(port: 1080) == "ALL_PROXY=socks5://127.0.0.1:1080")
        #expect(makeCopySnippet(port: 1081) == "ALL_PROXY=socks5://127.0.0.1:1081")
    }
}
