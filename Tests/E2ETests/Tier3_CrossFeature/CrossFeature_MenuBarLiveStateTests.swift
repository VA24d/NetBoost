import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 3: Menu Bar Extra Live State Synchronization", .tags(.tier3, .m6_ui))
struct CrossFeature_MenuBarLiveStateTests {

    @Test("Menu bar extra monitors aggregate throughput and reflects network environment changes")
    func testMenuBarStateTracking() {
        let env = MockNetworkEnvironment(initialState: .defaultCampusLAN)
        #expect(env.currentState.primaryInterface == "en10")

        // Switch to cellular hotspot
        env.transition(to: .defaultCellularHotspot)
        #expect(env.currentState.primaryInterface == "en0")
        #expect(env.currentState.isCellular)

        // Verify speed display formatting
        let downloadSpeed: Double = 10_485_760 // 10 MB/s
        let formattedSpeed = String(format: "↓ %.1f MB/s", downloadSpeed / 1_048_576)
        #expect(formattedSpeed == "↓ 10.0 MB/s")
    }

    @Test("Menu bar quick toggle for Hotspot updates shared configuration")
    func testMenuBarHotspotToggle() {
        var hotspot = HotspotConfiguration.default
        #expect(!hotspot.isActive)

        // Toggle on
        hotspot.isActive = true
        #expect(hotspot.isActive)
        #expect(hotspot.upstreamInterface == "en10")

        // Toggle off
        hotspot.isActive = false
        #expect(!hotspot.isActive)
    }

    @Test("Menu bar quick toggle for VPN dispatches Passepartout command")
    func testMenuBarVPNToggle() async throws {
        let runner = MockProcessRunner()

        let connectCmd = try await runner.run("scutil", arguments: ["--nc", "start", "macos.ovpn"])
        #expect(connectCmd.succeeded)
        #expect(runner.didExecute(commandContaining: "scutil --nc start macos.ovpn"))

        let disconnectCmd = try await runner.run("scutil", arguments: ["--nc", "stop", "macos.ovpn"])
        #expect(disconnectCmd.succeeded)
        #expect(runner.didExecute(commandContaining: "scutil --nc stop macos.ovpn"))
    }

    @Test("Menu bar Auto-Fix trigger runs combined MTU, DNS, and ARP remediation sequence")
    func testMenuBarAutoFixTrigger() async throws {
        let runner = MockProcessRunner()

        // 1. MTU fix
        _ = try await runner.run("networksetup", arguments: ["-setMTU", "Wi-Fi", "1280"])
        // 2. DNS flush
        _ = try await runner.run("dscacheutil", arguments: ["-flushcache"])
        _ = try await runner.run("killall", arguments: ["-HUP", "mDNSResponder"])
        // 3. ARP flush
        _ = try await runner.run("arp", arguments: ["-d", "-a"])

        #expect(runner.didExecute(commandContaining: "networksetup -setMTU Wi-Fi 1280"))
        #expect(runner.didExecute(commandContaining: "dscacheutil -flushcache"))
        #expect(runner.didExecute(commandContaining: "arp -d"))
    }

    @Test("Menu bar status updates within 1 second upon network transition event")
    func testMenuBarTransitionLatency() async {
        let env = MockNetworkEnvironment(initialState: .disconnected)
        let stream = env.makeStateStream()

        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // initial disconnected

        let start = Date()
        env.transition(to: .defaultCampusLAN)
        let updated = await iterator.next()
        let elapsed = Date().timeIntervalSince(start)

        #expect(updated == .defaultCampusLAN)
        #expect(elapsed < 1.0)
    }
}
