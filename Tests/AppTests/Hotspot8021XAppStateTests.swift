import Foundation
import Testing
import NetBoostCore
@testable import NetBoostApp

@Suite("AppTests: Hotspot 802.1X & Multi-Adapter State", .tags(.tier1, .m6_ui))
struct Hotspot8021XAppStateTests {

    @Test("802.1X protected upstream blocks canEnableHotspot and toggleHotspot with actionable error")
    @MainActor
    func test8021XProtectedUpstreamBlocksHotspot() async throws {
        let mockHotspot = MockAppHotspotController()
        let appState = AppState(hotspotController: mockHotspot, startBackgroundTimers: false)

        appState.updateEnvironment(.defaultCampusLAN)
        appState.upstreamInterface = "en10"
        appState.dot1XProtectedInterfaces = ["en10"]

        #expect(appState.isUpstreamProtectedBy8021X)
        #expect(!appState.canEnableHotspot)

        try await appState.toggleHotspot()

        #expect(!appState.isHotspotActive)
        #expect(!appState.isRadioBroadcasting)
        #expect(!mockHotspot.startCalled)
        #expect(appState.hotspotError?.contains("802.1X") == true)
        #expect(appState.hotspotError?.contains("eapolclient") == true)
        #expect(appState.hotspotError?.contains("en10") == true)
    }

    @Test("Clean non-802.1X physical Ethernet adapter enables hotspot and sorts ahead of 802.1X adapters")
    @MainActor
    func testShareableUpstreamInterfacesAndCleanSelection() async throws {
        let mockHotspot = MockAppHotspotController()
        let appState = AppState(hotspotController: mockHotspot, startBackgroundTimers: false)

        appState.hardwareInterfaces = [
            NetworkInterfaceInfo(
                bsdName: "en10",
                displayName: "USB 10/100 LAN",
                ipAddresses: [IPAddress(address: "10.1.36.52")],
                isPrimary: true,
                isUp: true
            ),
            NetworkInterfaceInfo(
                bsdName: "en9",
                displayName: "USB Gigabit Ethernet",
                ipAddresses: [IPAddress(address: "192.168.8.40")],
                isPrimary: false,
                isUp: true
            ),
            NetworkInterfaceInfo(
                bsdName: "en0",
                displayName: "Wi-Fi",
                ipAddresses: [IPAddress(address: "192.168.1.20")],
                isPrimary: false,
                isUp: true
            ),
            NetworkInterfaceInfo(
                bsdName: "utun4",
                displayName: "VPN Tunnel",
                ipAddresses: [IPAddress(address: "10.8.0.2")],
                isPrimary: false,
                isUp: true
            )
        ]
        appState.dot1XProtectedInterfaces = ["en10"]

        let shareable = appState.shareableUpstreamInterfaces
        #expect(shareable.map(\.bsdName) == ["en9", "en10"])

        appState.upstreamInterface = "en10"
        #expect(appState.isUpstreamProtectedBy8021X)
        #expect(!appState.canEnableHotspot)

        appState.upstreamInterface = "en9"
        #expect(!appState.isUpstreamProtectedBy8021X)
        #expect(appState.canEnableHotspot)

        try await appState.toggleHotspot()
        #expect(appState.isHotspotActive)
        #expect(mockHotspot.startCalled)
        #expect(mockHotspot.lastConfig?.upstreamInterface == "en9")
    }

    @Test("toggleHotspot resets active and broadcasting flags when startHotspot throws")
    @MainActor
    func testToggleHotspotFailureResetsState() async {
        let mockHotspot = MockAppHotspotController()
        mockHotspot.shouldThrowError = true
        let appState = AppState(hotspotController: mockHotspot, startBackgroundTimers: false)

        appState.upstreamInterface = "en10"
        appState.isRadioBroadcasting = true

        do {
            try await appState.toggleHotspot()
            Issue.record("Expected toggleHotspot to throw when controller fails")
        } catch {
            #expect(!appState.isHotspotActive)
            #expect(!appState.isRadioBroadcasting)
            #expect(!appState.hotspotConfig.isActive)
            #expect(appState.hotspotError != nil)
        }
    }

    @Test("refreshHotspotClients keeps isHotspotActive false when controller is inactive and not broadcasting")
    @MainActor
    func testRefreshHotspotClientsClearsStaleActiveFlag() async {
        let controller = HotspotNATController(configuration: .default)
        let appState = AppState(hotspotController: controller, startBackgroundTimers: false)

        appState.isHotspotActive = true
        appState.isRadioBroadcasting = true

        await appState.refreshHotspotClients()

        #expect(!appState.isRadioBroadcasting)
        #expect(!appState.isHotspotActive)
        #expect(appState.connectedClients.isEmpty)
    }
}
