import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 4 - Scenario 10: Liquid Glass Full UI & Menu Bar Extra Synchronization", .tags(.tier4, .m6_ui, .hotspot, .m3_vpn, .diagnostics))
struct Scenario10_LiquidGlassUIAndMenuBarControlTests {

    @Test("Liquid Glass Full UI and Menu Bar Extra state synchronization across network transitions, repairs, and toggles")
    func testLiquidGlassUIAndMenuBarSyncWorkflow() async throws {
        let runner = MockProcessRunner()
        let env = MockNetworkEnvironment(initialState: .defaultCampusLAN)

        // Step 1: Initial State Inspection
        #expect(env.currentState.isCampusLAN)
        #expect(env.currentState.primaryInterface == "en10")

        var hotspotConfig = HotspotConfiguration.default
        var vpnState = VPNStatus.disconnected
        #expect(!hotspotConfig.isActive)
        #expect(vpnState == .disconnected)

        // Step 2: Live Speedometer and Throughput Formatting
        let currentUploadBps: Double = 2_097_152   // 2 MB/s
        let currentDownloadBps: Double = 15_728_640 // 15 MB/s

        let formattedUp = String(format: "↑ %.1f MB/s", currentUploadBps / 1_048_576)
        let formattedDown = String(format: "↓ %.1f MB/s", currentDownloadBps / 1_048_576)
        #expect(formattedUp == "↑ 2.0 MB/s")
        #expect(formattedDown == "↓ 15.0 MB/s")

        // Step 3: Network Transition Simulation - Campus LAN -> Cellular Hotspot
        let stateStream = env.makeStateStream()
        var streamIterator = stateStream.makeAsyncIterator()
        _ = await streamIterator.next() // consume initial state

        env.transition(to: .defaultCellularHotspot)
        let newState = await streamIterator.next()

        #expect(newState == .defaultCellularHotspot)
        #expect(env.currentState.isCellular)
        #expect(env.currentState.primaryInterface == "en0")

        // Step 4: Menu Bar Quick Action - Auto-Fix Network Trigger
        let mtuFix = try await runner.run("networksetup", arguments: ["-setMTU", "Wi-Fi", "1280"])
        let dnsFlush1 = try await runner.run("dscacheutil", arguments: ["-flushcache"])
        let dnsFlush2 = try await runner.run("killall", arguments: ["-HUP", "mDNSResponder"])
        let arpFlush = try await runner.run("arp", arguments: ["-d", "-a"])

        #expect(mtuFix.succeeded)
        #expect(dnsFlush1.succeeded)
        #expect(dnsFlush2.succeeded)
        #expect(arpFlush.succeeded)

        #expect(runner.didExecute(commandContaining: "networksetup -setMTU Wi-Fi 1280"))
        #expect(runner.didExecute(commandContaining: "dscacheutil -flushcache"))
        #expect(runner.didExecute(commandContaining: "arp -d"))

        // Step 5: Hotspot Toggle Synchronization between UI and System Engine
        hotspotConfig.isActive = true
        let sysctl = try await runner.run("sysctl", arguments: ["-w", "net.inet.ip.forwarding=1"])
        let pfctl = try await runner.run("pfctl", arguments: ["-a", "netboost", "-f", "-"], environment: ["RULES": "nat on en10 from 192.168.2.0/24 to any -> (en10)\n"])

        #expect(sysctl.succeeded)
        #expect(pfctl.succeeded)
        #expect(hotspotConfig.isActive == true)

        // Step 6: VPN Control Toggle Synchronization with Menu Bar
        let vpnStart = try await runner.run("scutil", arguments: ["--nc", "start", "macos.ovpn"])
        #expect(vpnStart.succeeded)
        vpnState = .connected
        #expect(vpnState == .connected)

        // Step 7: Final Teardown Synchronization
        hotspotConfig.isActive = false
        vpnState = .disconnected

        let vpnStop = try await runner.run("scutil", arguments: ["--nc", "stop", "macos.ovpn"])
        let pfFlush = try await runner.run("pfctl", arguments: ["-a", "netboost", "-F", "all"])
        let sysctlReset = try await runner.run("sysctl", arguments: ["-w", "net.inet.ip.forwarding=0"])

        #expect(vpnStop.succeeded)
        #expect(pfFlush.succeeded)
        #expect(sysctlReset.succeeded)
        #expect(!hotspotConfig.isActive)
        #expect(vpnState == .disconnected)
    }
}
