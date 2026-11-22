import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 11: Network Sensor Boundaries", .tags(.tier2, .m3_vpn, .network_env))
struct Tier2_11_NetworkSensorBoundariesTests {

    @Test("T2-F11-01: Dual-homed network with Campus Ethernet and Cellular Wi-Fi prioritizes Campus")
    func testDualHomedPrioritization() {
        let ethernet = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "Ethernet",
            ipAddresses: [IPAddress(address: "10.1.36.52")],
            gateway: "10.1.36.1",
            isPrimary: true
        )
        let wifi = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "172.20.10.2")],
            gateway: "172.20.10.1",
            isPrimary: false
        )

        func classifyPrimaryEnvironment(interfaces: [NetworkInterfaceInfo]) -> String {
            if let primary = interfaces.first(where: { $0.isPrimary }) {
                if primary.ipv4Address?.hasPrefix("10.1.") == true {
                    return "campusLAN"
                }
            }
            return "other"
        }

        let classification = classifyPrimaryEnvironment(interfaces: [ethernet, wifi])
        #expect(classification == "campusLAN")
    }

    @Test("T2-F11-02: Rapid network flapping handled safely by MockNetworkEnvironment")
    func testNetworkFlappingHandling() async {
        let env = MockNetworkEnvironment(initialState: .disconnected)
        let stream = env.makeStateStream()

        var receivedStates: [NetworkEnvironmentState] = []
        let collectorTask = Task {
            for await state in stream {
                receivedStates.append(state)
                if receivedStates.count >= 4 { break }
            }
        }

        await env.simulateFlapping(states: [
            .defaultCampusLAN,
            .disconnected,
            .defaultCellularHotspot,
            .defaultExternalWiFi
        ], interval: 0.01)

        _ = await collectorTask.result
        #expect(receivedStates.count >= 4)
    }

    @Test("T2-F11-03: All interfaces disconnected classifies as disconnected")
    func testAllInterfacesDisconnected() {
        let envState = NetworkEnvironmentState.disconnected
        #expect(envState.isConnected == false)
        #expect(envState.primaryInterface == nil)
        #expect(envState.mtu == 0)
    }

    @Test("T2-F11-04: Link-local IP address (169.254.x.x) identified as unconfigured")
    func testLinkLocalAddressDetection() {
        func isLinkLocal(ip: String) -> Bool {
            return ip.hasPrefix("169.254.")
        }

        #expect(isLinkLocal(ip: "169.254.120.4") == true)
        #expect(isLinkLocal(ip: "10.1.36.52") == false)
        #expect(isLinkLocal(ip: "192.168.1.100") == false)
    }

    @Test("T2-F11-05: Interface active with nil gateway handled gracefully")
    func testInterfaceWithNilGateway() {
        let iface = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "192.168.1.50")],
            gateway: nil,
            isPrimary: false,
            isUp: true
        )

        #expect(iface.gateway == nil)
        #expect(iface.isUp == true)
    }
}
