import Testing
import Foundation
@testable import NetBoostCore
@testable import NetBoostApp

@Suite("Tier 5 - Per-Adapter iCloud Private Relay Isolation Tests", .tags(.tier5, .socks5))
struct Tier5_PerAdapterPrivateRelayTests {

    // MARK: - Test 1: Loopback Binding Isolation

    @Test("T5-Relay-01: InterfaceProxyDispatcher binds strictly to local loopback ports")
    func testProxyDispatcherLocalLoopbackBinding() {
        let dispatcher = InterfaceProxyDispatcher()

        #expect(dispatcher.portConfigs[1080]?.targetInterface == "en10")
        #expect(dispatcher.portConfigs[1081]?.targetInterface == "en0")
        #expect(dispatcher.portConfigs[1082]?.mode == .loadBalanced)

        // Verify shell snippets point exclusively to 127.0.0.1
        let s1080 = dispatcher.generateShellSnippet(port: 1080)
        let s1081 = dispatcher.generateShellSnippet(port: 1081)
        let s1082 = dispatcher.generateShellSnippet(port: 1082)

        #expect(s1080.contains("127.0.0.1:1080"))
        #expect(s1081.contains("127.0.0.1:1081"))
        #expect(s1082.contains("127.0.0.1:1082"))

        // Confirms no global proxy command is embedded
        #expect(!s1080.contains("networksetup"))
        #expect(!s1080.contains("-setwebproxy"))
        #expect(!s1080.contains("-setsocksfirewallproxy"))
    }

    // MARK: - Test 2: Process-Scoped Shell Snippets

    @Test("T5-Relay-02: Shell snippets provide process-scoped proxy without global network pollution")
    func testProcessScopedProxySnippets() {
        let generator = ShellEnvGenerator(host: "127.0.0.1", port: 1080)
        let exportCmd = generator.allExports(for: .zsh)

        #expect(exportCmd.contains("ALL_PROXY=socks5://127.0.0.1:1080"))
        #expect(exportCmd.contains("all_proxy=socks5://127.0.0.1:1080"))
        #expect(exportCmd.contains("HTTP_PROXY=http://127.0.0.1:1080"))
        #expect(exportCmd.contains("HTTPS_PROXY=http://127.0.0.1:1080"))
        #expect(exportCmd.contains("NO_PROXY=localhost,127.0.0.1,10.0.0.0/8"))
    }

    // MARK: - Test 3: PF NAT Anchor Rule Scoping

    @Test("T5-Relay-03: PFNATAnchorManager rule strictness avoids altering Apple Private Relay tunnels")
    func testPFNATAnchorRuleScoping() {
        let manager = PFNATAnchorManager(
            anchorName: "netboost",
            upstreamInterface: "en10",
            clientSubnet: "192.168.2.0/24"
        )

        let rule = manager.generateNATRule()

        // Rule must be strictly scoped to upstreamInterface and clientSubnet
        #expect(rule.contains("nat on en10 from 192.168.2.0/24 to any -> (en10)"))
        // Must NOT alter Apple Private Relay interfaces (utun3, utun4, etc.)
        #expect(!rule.contains("utun"))
        #expect(!rule.contains("pass all"))
        #expect(!rule.contains("block all"))
    }

    // MARK: - Test 4: Per-Adapter Interface Isolation

    @Test("T5-Relay-04: Network environment differentiates campus LAN from Wi-Fi and Cellular")
    func testNetworkEnvironmentIsolation() {
        let campus = NetworkEnvironmentState.campusLAN(interface: "en10", ip: "10.1.36.52", gateway: "10.1.36.1", mtu: 1500)
        let wifi = NetworkEnvironmentState.externalWiFi(interface: "en0", ip: "192.168.1.100", gateway: "192.168.1.1", mtu: 1500)
        let cellular = NetworkEnvironmentState.cellularHotspot(interface: "en9", ip: "172.20.10.2", gateway: "172.20.10.1", mtu: 1280)

        #expect(campus.isCampusLAN == true)
        #expect(wifi.isCampusLAN == false)
        #expect(cellular.isCampusLAN == false)

        #expect(campus.primaryInterface == "en10")
        #expect(wifi.primaryInterface == "en0")
        #expect(cellular.primaryInterface == "en9")
    }

    // MARK: - Test 5: Route Pinning Subnet Restriction

    @Test("T5-Relay-05: Route pinning targets specific campus subnets without hijacking default route")
    func testRoutePinningSubnetRestriction() {
        let subnets = RoutePinningEngine.campusSubnets
        #expect(subnets.contains("10.8.0.0/16"))
        #expect(subnets.contains("10.4.0.0/16"))

        // Default route 0.0.0.0/0 must NEVER be pinned to en10 (preserves internet/Private Relay)
        #expect(!subnets.contains("0.0.0.0/0"))
        #expect(!subnets.contains("default"))
    }

    // MARK: - Test 6: Web Proxy Cleaner Scope

    @Test("T5-Relay-06: Proxy cleaner selectively disables proxy states per named service")
    func testProxyCleanerPerServiceScope() {
        let cmdAuto = ProxySettingsManager.makeDisableAutoProxyCommand(service: "USB 10/100 LAN")
        let cmdWeb = ProxySettingsManager.makeDisableWebProxyCommand(service: "USB 10/100 LAN")
        let cmdSecure = ProxySettingsManager.makeDisableSecureWebProxyCommand(service: "USB 10/100 LAN")

        #expect(cmdAuto.contains("USB 10/100 LAN"))
        #expect(cmdAuto.contains("-setautoproxystate"))
        #expect(cmdWeb.contains("-setwebproxystate"))
        #expect(cmdSecure.contains("-setsecurewebproxystate"))

        // Confirms it targets the specified service only
        #expect(!cmdAuto.contains("Wi-Fi"))
    }
}
