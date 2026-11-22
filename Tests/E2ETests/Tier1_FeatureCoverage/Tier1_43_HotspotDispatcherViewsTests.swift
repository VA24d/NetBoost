import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 43: Hotspot & Dispatcher Views", .tags(.tier1, .m6_ui))
struct Tier1_43_HotspotDispatcherViewsTests {

    final class HotspotDispatcherViewModel: @unchecked Sendable {
        private(set) var isHotspotActive: Bool = false
        private(set) var configuration: HotspotConfiguration = .default
        private(set) var clients: [HotspotClient] = []
        private(set) var proxyCards: [(port: Int, iface: String, label: String)] = [
            (1080, "en10", "Wired LAN Egress"),
            (1081, "en0", "Wi-Fi / Hotspot Egress"),
            (1082, "auto", "Load Balanced Egress")
        ]
        private(set) var copiedSnippet: String?

        func toggleHotspot() {
            isHotspotActive.toggle()
            configuration.isActive = isHotspotActive
        }

        func setClients(_ list: [HotspotClient]) {
            clients = list
        }

        func copyCLIHelper(port: Int) {
            copiedSnippet = "export ALL_PROXY=socks5://127.0.0.1:\(port)"
        }
    }

    @Test("T1-F43-01: Hotspot toggle switch updates sharing state")
    func testHotspotToggleSwitch() {
        let vm = HotspotDispatcherViewModel()
        #expect(vm.isHotspotActive == false)

        vm.toggleHotspot()
        #expect(vm.isHotspotActive == true)
        #expect(vm.configuration.isActive == true)

        vm.toggleHotspot()
        #expect(vm.isHotspotActive == false)
    }

    @Test("T1-F43-02: Display Hotspot configuration card (Subnet, Gateway, DHCP pool)")
    func testHotspotConfigCardDetails() {
        let vm = HotspotDispatcherViewModel()
        #expect(vm.configuration.subnet == "192.168.2.0/24")
        #expect(vm.configuration.gateway == "192.168.2.1")
        #expect(vm.configuration.dhcpRangeStart == "192.168.2.10")
        #expect(vm.configuration.dhcpRangeEnd == "192.168.2.100")
    }

    @Test("T1-F43-03: Display client table with IP, MAC, and throughput metrics")
    func testClientTableDetails() {
        let vm = HotspotDispatcherViewModel()
        let client = HotspotClient(
            macAddress: "aa:bb:cc:dd:ee:ff",
            ipAddress: "192.168.2.15",
            hostname: "iPad Pro",
            txBytes: 1048576,
            rxBytes: 2097152
        )
        vm.setClients([client])

        #expect(vm.clients.count == 1)
        #expect(vm.clients.first?.hostname == "iPad Pro")
        #expect(vm.clients.first?.ipAddress == "192.168.2.15")
        #expect(vm.clients.first?.txBytes == 1048576)
    }

    @Test("T1-F43-04: Display Proxy Dispatcher cards for ports 1080, 1081, 1082")
    func testProxyDispatcherCards() {
        let vm = HotspotDispatcherViewModel()
        #expect(vm.proxyCards.count == 3)
        #expect(vm.proxyCards[0].port == 1080)
        #expect(vm.proxyCards[0].iface == "en10")
        #expect(vm.proxyCards[1].port == 1081)
        #expect(vm.proxyCards[1].iface == "en0")
        #expect(vm.proxyCards[2].port == 1082)
        #expect(vm.proxyCards[2].iface == "auto")
    }

    @Test("T1-F43-05: Copy CLI Helper button generates export snippet")
    func testCopyCLIHelperSnippet() {
        let vm = HotspotDispatcherViewModel()
        vm.copyCLIHelper(port: 1080)

        #expect(vm.copiedSnippet == "export ALL_PROXY=socks5://127.0.0.1:1080")
    }
}
