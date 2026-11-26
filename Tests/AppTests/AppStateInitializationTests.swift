import Foundation
import Testing
import NetBoostCore
@testable import NetBoostApp

@Suite("AppTests: AppState Initialization & Injection", .tags(.tier1, .m6_ui))
struct AppStateInitializationTests {

    @Test("AppState initializes with default production controllers and clean baseline metrics")
    @MainActor
    func testDefaultInitialization() {
        let appState = AppState(startBackgroundTimers: false)

        #expect(appState.selectedTab == .dashboard)
        #expect(appState.currentDownloadBps == 0)
        #expect(appState.currentUploadBps == 0)
        #expect(appState.smoothedDownloadBps == 0)
        #expect(appState.smoothedUploadBps == 0)
        #expect(appState.menuBarThroughputText.contains("0 B/s"))
        #expect(appState.isAutoFixRunning == false)
        #expect(appState.autoFixSummary == nil)
        #expect(appState.isHotspotActive == false)
        #expect(appState.isProxyActive == false)
        #expect(appState.vpnStatus == .disconnected)
        #expect(appState.activeDownloadTask == nil)
        #expect(appState.activeIssues.isEmpty)
        #expect(appState.repairLogs.isEmpty)
    }

    @Test("AppState accepts custom mock protocol controller injection")
    @MainActor
    func testMockControllerInjection() {
        let mockProxy = MockAppProxyDispatcher()
        let mockVPN = MockAppVPNController()
        let mockDownloader = MockAppDownloadManager()
        let mockDoctor = MockAppCampusDoctor()
        let mockHotspot = MockAppHotspotController()
        let mockLLM = MockAppLLMDoctorBridge()
        let mockClipboard = MockAppClipboardWatcher()

        let appState = AppState(
            proxyDispatcher: mockProxy,
            vpnController: mockVPN,
            downloadManager: mockDownloader,
            campusDoctor: mockDoctor,
            hotspotController: mockHotspot,
            llmBridge: mockLLM,
            pasteboardWatcher: mockClipboard,
            startBackgroundTimers: false
        )

        #expect(appState.proxyDispatcher is MockAppProxyDispatcher)
        #expect(appState.vpnController is MockAppVPNController)
        #expect(appState.downloadManager is MockAppDownloadManager)
        #expect(appState.campusDoctor is MockAppCampusDoctor)
        #expect(appState.hotspotController is MockAppHotspotController)
        #expect(appState.llmBridge is MockAppLLMDoctorBridge)
        #expect(appState.pasteboardWatcher is MockAppClipboardWatcher)
    }

    @Test("Network environment updates sync primary interface and active state pill")
    @MainActor
    func testNetworkEnvironmentStateSync() {
        let appState = AppState(startBackgroundTimers: false)

        // Wired LAN
        appState.updateEnvironment(.defaultCampusLAN)
        #expect(appState.primaryInterface == "en10")
        #expect(appState.primaryInterfaceIP == "10.1.36.52")
        #expect(appState.activeStatePill == "Wired LAN (Direct)")

        // Cellular Hotspot
        appState.updateEnvironment(.defaultCellularHotspot)
        #expect(appState.primaryInterface == "en0")
        #expect(appState.primaryInterfaceIP == "172.20.10.2")
        #expect(appState.activeStatePill == "Cellular Hotspot (VPN)")

        // Disconnected
        appState.updateEnvironment(.disconnected)
        #expect(appState.activeStatePill == "Offline")
    }

    @Test("Proxy ports dictionary initialized with 1080, 1081, 1082 mappings")
    @MainActor
    func testProxyPortsDefaultMappings() {
        let appState = AppState(startBackgroundTimers: false)

        #expect(appState.proxyPorts[1080] == "en10")
        #expect(appState.proxyPorts[1081] == "en0")
        #expect(appState.proxyPorts[1082] == "auto")
    }
}
