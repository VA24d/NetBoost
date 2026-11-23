import Foundation
import Testing
import NetBoostCore
@testable import NetBoostApp

@Suite("AppTests: AppState Action Delegation", .tags(.tier1, .m6_ui))
struct AppStateActionDelegationTests {

    @Test("Proxy toggle starts and stops dispatcher on configured ports")
    @MainActor
    func testProxyToggleDelegation() async throws {
        let mockProxy = MockAppProxyDispatcher()
        let appState = AppState(proxyDispatcher: mockProxy, startBackgroundTimers: false)

        #expect(!appState.isProxyActive)
        try await appState.toggleProxy()
        #expect(appState.isProxyActive)
        #expect(mockProxy.startCalled)
        #expect(mockProxy.startedPorts.count == 3)

        try await appState.toggleProxy()
        #expect(!appState.isProxyActive)
        #expect(mockProxy.stopCalled)
    }

    @Test("Shell snippet generation delegates to proxy dispatcher and formats correctly")
    @MainActor
    func testShellSnippetDelegation() {
        let mockProxy = MockAppProxyDispatcher()
        let appState = AppState(proxyDispatcher: mockProxy, startBackgroundTimers: false)

        let snippet = appState.generateShellSnippet(port: 1080)
        #expect(snippet == "export ALL_PROXY=socks5://127.0.0.1:1080")
        #expect(appState.copiedSnippetMessage?.contains("1080") == true)
    }

    @Test("VPN toggle connects and disconnects profile with 0.5s debounce protection")
    @MainActor
    func testVPNToggleDelegationAndDebounce() async throws {
        let mockVPN = MockAppVPNController()
        let appState = AppState(vpnController: mockVPN, startBackgroundTimers: false)

        #expect(appState.vpnStatus == .disconnected)

        // First toggle: Connects
        try await appState.toggleVPN()
        #expect(appState.vpnStatus == .connected)
        #expect(mockVPN.connectCalled)
        #expect(mockVPN.lastProfileName == "macos.ovpn")

        // Immediate toggle (< 0.5s): Debounced, no action
        try await appState.toggleVPN()
        #expect(appState.vpnStatus == .connected) // Still connected because debounced

        // Advance debounce time
        appState.lastVPNToggleTime = Date().addingTimeInterval(-1.0)

        // Subsequent toggle: Disconnects
        try await appState.toggleVPN()
        #expect(appState.vpnStatus == .disconnected)
        #expect(mockVPN.disconnectCalled)
    }

    @Test("Hotspot toggle delegates start and stop to HotspotController")
    @MainActor
    func testHotspotToggleDelegation() async throws {
        let mockHotspot = MockAppHotspotController()
        let appState = AppState(hotspotController: mockHotspot, startBackgroundTimers: false)
        appState.upstreamInterface = "en10"

        #expect(!appState.isHotspotActive)
        try await appState.toggleHotspot()
        #expect(appState.isHotspotActive)
        #expect(mockHotspot.startCalled)

        try await appState.toggleHotspot()
        #expect(!appState.isHotspotActive)
        #expect(mockHotspot.stopCalled)
    }

    @Test("Auto-Fix executes priority sequence: MTU (1280) -> DNS -> ARP")
    @MainActor
    func testAutoFixPrioritySequence() async {
        let mockDoctor = MockAppCampusDoctor()
        let appState = AppState(campusDoctor: mockDoctor, startBackgroundTimers: false)

        #expect(!appState.isAutoFixRunning)
        #expect(appState.autoFixSummary == nil)

        await appState.executeAutoFix()

        #expect(!appState.isAutoFixRunning)
        #expect(appState.autoFixSummary?.contains("Auto-Fix Complete") == true)
        #expect(mockDoctor.executionLog == ["fixMTU_Wi-Fi_1280", "flushDNS", "flushARP"])
    }

    @Test("Download accelerator lifecycle delegates start, pause, resume, cancel")
    @MainActor
    func testDownloadAcceleratorDelegation() async throws {
        let mockDownloader = MockAppDownloadManager()
        let appState = AppState(downloadManager: mockDownloader, startBackgroundTimers: false)

        appState.downloadURLInput = "https://speed.campus.net/testfile.iso"
        appState.selectedChunkCount = 12

        try await appState.startDownload()
        #expect(mockDownloader.startDownloadCalled)
        #expect(mockDownloader.lastChunksCount == 12)
        #expect(appState.activeDownloadTask != nil)

        try await appState.pauseDownload()
        #expect(mockDownloader.pauseCalled)

        try await appState.resumeDownload()
        #expect(mockDownloader.resumeCalled)

        try await appState.cancelDownload()
        #expect(mockDownloader.cancelCalled)
        #expect(appState.activeDownloadTask == nil)
    }

    @Test("AI tool execution delegates to LLMDoctorBridge and logs tool result")
    @MainActor
    func testAIToolExecutionDelegation() async throws {
        let mockLLM = MockAppLLMDoctorBridge()
        let appState = AppState(llmBridge: mockLLM, startBackgroundTimers: false)

        let result = try await appState.approveAndExecuteTool(
            name: "fix_mtu",
            arguments: ["interface": "Wi-Fi", "mtu": "1280"]
        )

        #expect(result.success)
        #expect(mockLLM.executedTools.contains("fix_mtu"))
        #expect(appState.toolExecutionLogs.count == 1)
        #expect(appState.toolExecutionLogs.first?.toolName == "fix_mtu")
    }
}
