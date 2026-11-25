import Foundation
import Testing
import NetBoostCore
@testable import NetBoostApp

@Suite("AppTests: Extended AppState Wiring & Utilities", .tags(.tier1, .m6_ui))
struct ExtendedAppStateWiringTests {

    // MARK: - SpeedFormatter Bytes & Duration

    @Test("SpeedFormatter.formatBytes formats 0, bytes, KB, MB, and GB boundaries")
    func testSpeedFormatterBytes() {
        #expect(SpeedFormatter.formatBytes(0) == "0 B")
        #expect(SpeedFormatter.formatBytes(-10) == "0 B")
        #expect(SpeedFormatter.formatBytes(512) == "512 B")
        #expect(SpeedFormatter.formatBytes(1_536) == "1.5 KB")
        #expect(SpeedFormatter.formatBytes(5_242_880) == "5.0 MB")
        #expect(SpeedFormatter.formatBytes(2_147_483_648) == "2.00 GB")
    }

    @Test("SpeedFormatter.formatDuration formats seconds, minutes, hours, and non-finite bounds")
    func testSpeedFormatterDuration() {
        #expect(SpeedFormatter.formatDuration(0) == "0s")
        #expect(SpeedFormatter.formatDuration(45) == "45s")
        #expect(SpeedFormatter.formatDuration(125) == "2m 05s")
        #expect(SpeedFormatter.formatDuration(3665) == "1h 01m")
        #expect(SpeedFormatter.formatDuration(Double.infinity) == "--")
        #expect(SpeedFormatter.formatDuration(-5) == "--")
        #expect(SpeedFormatter.formatDuration(Double.nan) == "--")
    }

    // MARK: - AI Doctor Bridge Chat & Tool Wiring

    @Test("AppState.sendChatMessage delegates to bridge.sendChat with trimmed text and report")
    @MainActor
    func testSendChatMessageDelegatesToSendChat() async {
        let harness = AppStateTestHarness(startBackgroundTimers: false)
        harness.llm.mockAnalysis = LLMAnalysis(
            diagnosis: "Gateway RTT elevated; flush ARP recommended.",
            recommendedActions: ["flush_arp"]
        )

        await harness.appState.sendChatMessage(text: "  Why is gateway ping high?  ")

        #expect(harness.llm.sendChatCalled)
        #expect(!harness.llm.telemetrySent)
        #expect(harness.llm.lastChatMessage == "Why is gateway ping high?")
        #expect(harness.llm.lastChatReport != nil)
        #expect(harness.llm.lastChatEndpoint == harness.appState.lmStudioEndpoint)
        #expect(harness.doctor.executionLog.contains("runFullDiagnostics"))
        #expect(harness.appState.isLMStudioConnected)
        #expect(!harness.appState.isAIAnalyzing)
        #expect(harness.appState.chatMessages.count == 2)
        #expect(harness.appState.chatMessages.first?.role == "user")
        #expect(harness.appState.chatMessages.first?.content == "Why is gateway ping high?")
        #expect(harness.appState.chatMessages.last?.role == "assistant")
        #expect(harness.appState.chatMessages.last?.content == "Gateway RTT elevated; flush ARP recommended.")
    }

    @Test("AppState.sendChatMessage ignores blank input and handles errors cleanly")
    @MainActor
    func testSendChatMessageEdgeCases() async {
        let harness = AppStateTestHarness(startBackgroundTimers: false)

        await harness.appState.sendChatMessage(text: "   \n\t  ")
        #expect(!harness.llm.sendChatCalled)
        #expect(harness.appState.chatMessages.isEmpty)

        harness.llm.shouldThrowError = true
        await harness.appState.sendChatMessage(text: "Check DNS")
        #expect(!harness.appState.isLMStudioConnected)
        #expect(!harness.appState.isAIAnalyzing)
        #expect(harness.appState.chatMessages.count == 2)
        #expect(harness.appState.chatMessages.last?.content.contains("Could not reach LM Studio") == true)
    }

    @Test("AppState.approveAndExecuteTool executes tool and appends tool result to bridge")
    @MainActor
    func testApproveAndExecuteToolAppendsResult() async throws {
        let harness = AppStateTestHarness(startBackgroundTimers: false)

        let result = try await harness.appState.approveAndExecuteTool(
            name: "fix_mtu",
            arguments: ["service": "Wi-Fi", "mtu": "1280"],
            toolCallId: "call_test_42"
        )

        #expect(result.success)
        #expect(harness.llm.executedTools == ["fix_mtu"])
        #expect(harness.llm.appendedToolResults.count == 1)
        #expect(harness.llm.appendedToolResults.first?.toolCallId == "call_test_42")
        #expect(harness.llm.appendedToolResults.first?.name == "fix_mtu")
        #expect(harness.llm.appendedToolResults.first?.output == result.output)
        #expect(harness.appState.toolExecutionLogs.count == 1)
        #expect(harness.appState.toolExecutionLogs.first?.toolName == "fix_mtu")
        #expect(harness.appState.toolExecutionLogs.first?.output == result.output)

        // Default auto-generated toolCallId path
        _ = try await harness.appState.approveAndExecuteTool(
            name: "flush_dns",
            arguments: [:]
        )
        #expect(harness.llm.appendedToolResults.count == 2)
        #expect(harness.llm.appendedToolResults.last?.toolCallId.hasPrefix("call_") == true)
        #expect(harness.llm.appendedToolResults.last?.name == "flush_dns")
    }

    // MARK: - Download Checksum Verification & Directory

    @Test("AppState.verifyChecksum honors SHA-256, SHA-1, and MD5 algorithms on real temp file")
    @MainActor
    func testVerifyChecksumAlgorithmsOnDiskFile() async throws {
        let tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("netboost-checksum-\(UUID().uuidString).bin")
        let payload = Data("NetBoost deterministic checksum payload 2026".utf8)
        try payload.write(to: tempFileURL)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        let sha256Hex = ChecksumValidator.computeChecksum(for: payload, algorithm: .sha256)
        let sha1Hex = ChecksumValidator.computeChecksum(for: payload, algorithm: .sha1)
        let md5Hex = ChecksumValidator.computeChecksum(for: payload, algorithm: .md5)

        let harness = AppStateTestHarness(startBackgroundTimers: false)
        let appState = harness.appState

        // Missing task or empty checksum yields false and nil status
        let missingResult = await appState.verifyChecksum()
        #expect(!missingResult)
        #expect(appState.checksumMatchStatus == nil)

        appState.activeDownloadTask = DownloadTaskInfo(
            url: URL(string: "https://speed.campus.net/payload.bin")!,
            destinationURL: tempFileURL,
            totalBytes: Int64(payload.count),
            downloadedBytes: Int64(payload.count),
            status: .completed
        )

        // SHA-256 PASS & FAIL
        appState.selectedChecksumAlgorithm = "SHA-256"
        appState.expectedChecksum = sha256Hex
        let sha256Pass = await appState.verifyChecksum()
        #expect(sha256Pass)
        #expect(appState.checksumMatchStatus == true)
        #expect(appState.repairLogs.last?.contains("SHA-256") == true)
        #expect(appState.repairLogs.last?.contains("PASS") == true)

        appState.expectedChecksum = String(repeating: "0", count: 64)
        let sha256Fail = await appState.verifyChecksum()
        #expect(!sha256Fail)
        #expect(appState.checksumMatchStatus == false)
        #expect(appState.repairLogs.last?.contains("FAIL") == true)

        // SHA-1 PASS & FAIL (including proving SHA-256 digest does not pass when SHA-1 is selected)
        appState.selectedChecksumAlgorithm = "SHA-1"
        appState.expectedChecksum = sha1Hex
        let sha1Pass = await appState.verifyChecksum()
        #expect(sha1Pass)
        #expect(appState.checksumMatchStatus == true)

        appState.expectedChecksum = sha256Hex
        let sha1CrossFail = await appState.verifyChecksum()
        #expect(!sha1CrossFail)
        #expect(appState.checksumMatchStatus == false)

        appState.expectedChecksum = String(repeating: "a", count: 40)
        let sha1Fail = await appState.verifyChecksum()
        #expect(!sha1Fail)
        #expect(appState.checksumMatchStatus == false)

        // MD5 PASS & FAIL
        appState.selectedChecksumAlgorithm = "MD5"
        appState.expectedChecksum = md5Hex
        let md5Pass = await appState.verifyChecksum()
        #expect(md5Pass)
        #expect(appState.checksumMatchStatus == true)

        appState.expectedChecksum = String(repeating: "f", count: 32)
        let md5Fail = await appState.verifyChecksum()
        #expect(!md5Fail)
        #expect(appState.checksumMatchStatus == false)
    }

    @Test("AppState.downloadDirectory defaults to valid non-empty Downloads path in headless sandbox")
    @MainActor
    func testDownloadDirectoryDefaultAndDestination() async throws {
        let harness = AppStateTestHarness(startBackgroundTimers: false)
        let appState = harness.appState
        let expectedDefault = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        #expect(appState.downloadDirectory.isFileURL)
        #expect(!appState.downloadDirectory.path.isEmpty)
        #expect(appState.downloadDirectory == expectedDefault)

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: appState.downloadDirectory.path, isDirectory: &isDirectory) {
            #expect(isDirectory.boolValue)
            #expect(FileManager.default.isWritableFile(atPath: appState.downloadDirectory.path))
        }

        appState.downloadURLInput = "https://speed.campus.net/ubuntu.iso"
        try await appState.startDownload()
        #expect(appState.activeDownloadTask?.destinationURL == appState.downloadDirectory.appendingPathComponent("ubuntu.iso"))
    }

    // MARK: - Hotspot Validation & Toggle Guard

    @Test("AppState.hotspotPasswordValidationError validates SSID and passphrase lengths across WPA modes")
    @MainActor
    func testHotspotPasswordValidationError() {
        let harness = AppStateTestHarness(startBackgroundTimers: false)
        let appState = harness.appState

        let securityModes: [HotspotSecurityType] = [.wpa2Wpa3Transition, .wpa3Personal, .wpa2Personal]
        for mode in securityModes {
            appState.hotspotSecurityType = mode
            appState.hotspotSSID = "NetBoost"

            // < 8 characters rejected
            appState.hotspotPassword = ""
            #expect(appState.hotspotPasswordValidationError != nil)
            appState.hotspotPassword = "1234567"
            #expect(appState.hotspotPasswordValidationError != nil)

            // > 63 characters rejected
            appState.hotspotPassword = String(repeating: "a", count: 64)
            #expect(appState.hotspotPasswordValidationError != nil)

            // Valid 8 and 63 boundaries accepted
            appState.hotspotPassword = "12345678"
            #expect(appState.hotspotPasswordValidationError == nil)
            appState.hotspotPassword = String(repeating: "z", count: 63)
            #expect(appState.hotspotPasswordValidationError == nil)

            // Empty / whitespace / >32-byte SSID rejected
            appState.hotspotSSID = ""
            #expect(appState.hotspotPasswordValidationError != nil)
            appState.hotspotSSID = "   "
            #expect(appState.hotspotPasswordValidationError != nil)
            appState.hotspotSSID = String(repeating: "x", count: 33)
            #expect(appState.hotspotPasswordValidationError != nil)
        }
    }

    @Test("AppState.toggleHotspot refuses short passphrase and sets hotspotError without starting controller")
    @MainActor
    func testToggleHotspotRejectsShortPassword() async throws {
        let harness = AppStateTestHarness(startBackgroundTimers: false)
        let appState = harness.appState

        appState.updateEnvironment(.defaultCampusLAN)
        appState.upstreamInterface = "en10"
        appState.hotspotSSID = "NetBoost"
        appState.hotspotPassword = "123"
        appState.hotspotSecurityType = .wpa2Wpa3Transition

        #expect(appState.canEnableHotspot)

        try await appState.toggleHotspot()

        #expect(!appState.isHotspotActive)
        #expect(!harness.hotspot.startCalled)
        #expect(appState.hotspotError != nil)
        #expect(appState.hotspotError == appState.hotspotPasswordValidationError)
        #expect(appState.repairLogs.contains(where: { $0.contains("Hotspot configuration invalid") }))
    }

    // MARK: - Background Tasks & Pasteboard Watcher Lifecycle

    @Test("AppState.startBackgroundTasks and stopBackgroundTasks invoke pasteboardWatcher lifecycle")
    @MainActor
    func testBackgroundTasksStartAndStopPasteboardWatcher() {
        let harness = AppStateTestHarness(startBackgroundTimers: false)
        let appState = harness.appState

        #expect(!harness.clipboard.startMonitoringCalled)
        #expect(!harness.clipboard.stopMonitoringCalled)

        appState.startBackgroundTasks()
        #expect(harness.clipboard.startMonitoringCalled)
        #expect(harness.clipboard.lastMonitoringInterval == 1.5)
        #expect(!harness.clipboard.stopMonitoringCalled)
        #expect(harness.pathMonitor.isStarted)

        appState.stopBackgroundTasks()
        #expect(harness.clipboard.stopMonitoringCalled)
        #expect(harness.pathMonitor.isCancelled)
    }

    // MARK: - Campus Doctor Service Selection

    @Test("AppState.manualFixMTU passes selectedRepairService to campusDoctor.fixMTU")
    @MainActor
    func testSelectedRepairServicePassedToFixMTU() async throws {
        let harness = AppStateTestHarness(startBackgroundTimers: false)
        let appState = harness.appState

        appState.selectedRepairService = "USB 10/100 LAN"
        try await appState.manualFixMTU()
        try await appState.manualDisableIPv6()

        #expect(harness.doctor.executionLog.contains("fixMTU_USB 10/100 LAN_1280"))
        #expect(harness.doctor.executionLog.contains("disableIPv6_USB 10/100 LAN"))

        await appState.executeAutoFix()
        #expect(harness.doctor.executionLog.contains("fixMTU_USB 10/100 LAN_1280"))
        #expect(harness.doctor.executionLog.contains("flushDNS"))
        #expect(harness.doctor.executionLog.contains("flushARP"))
    }

    // MARK: - VPN Profile Import & Route Conflict Detection

    @Test("AppState.checkRouteConflicts populates routeConflicts from loadedProfileInfo set via importOVPNProfile")
    @MainActor
    func testCheckRouteConflictsUsesImportedProfileInfo() {
        let harness = AppStateTestHarness(startBackgroundTimers: false)
        let appState = harness.appState

        let profile = VPNProfileInfo(
            name: "campus_overlap.ovpn",
            serverAddress: "vpn.campus.net",
            routes: [
                VPNRouteEntry(destinationSubnet: "10.1.0.0", mask: "255.255.0.0")
            ],
            isCampusSplit: false
        )
        harness.vpn.mockParsedProfile = profile
        harness.vpn.mockConflicts = ["Mock fallback conflict"]

        // 1. With hardwareInterfaces populated, RouteConflictDetector evaluates loadedProfileInfo directly
        appState.hardwareInterfaces = AppStateTestHarness.makeCampusInterfaceFixtures()
        appState.importOVPNProfile(url: URL(fileURLWithPath: "/tmp/campus_overlap.ovpn"))

        #expect(appState.loadedProfileInfo == profile)
        #expect(appState.parsedRoutes == profile.routes)
        #expect(appState.activeVPNProfile == "campus_overlap.ovpn")
        #expect(appState.vpnError == nil)
        #expect(appState.conflictReport != nil)
        #expect(!appState.routeConflicts.isEmpty)
        #expect(appState.routeConflicts.contains(where: { $0.contains("10.1.0.0") || $0.contains("Full tunnel") }))

        // Re-running checkRouteConflicts keeps conflicts populated from loadedProfileInfo
        appState.routeConflicts = []
        appState.checkRouteConflicts()
        #expect(!appState.routeConflicts.isEmpty)

        // 2. With empty hardwareInterfaces, delegates to vpnController.detectConflicts with loadedProfileInfo
        appState.hardwareInterfaces = []
        appState.checkRouteConflicts()
        #expect(appState.conflictReport == nil)
        #expect(harness.vpn.lastConflictCheckedProfile == profile)
        #expect(appState.routeConflicts == ["Mock fallback conflict"])
    }

    // MARK: - Route Pinning Helper & Authorization State

    @Test("AppState route pinning rejects malformed CIDR cleanly without elevation")
    @MainActor
    func testRoutePinningValidationViaHarness() async {
        let harness = AppStateTestHarness(startBackgroundTimers: false)
        let appState = harness.appState

        await appState.pinSubnet("invalid_subnet")
        #expect(appState.routePinResultMessage?.contains("Malformed subnet notation") == true)
        #expect(appState.repairLogs.contains(where: { $0.contains("Route pin invalid_subnet") }))

        await appState.unpinSubnet("invalid_subnet")
        #expect(appState.routePinResultMessage?.contains("Malformed subnet notation") == true)
    }

    @Test("PrivilegeHelper non-destructive detection and AppState default authorization summary")
    @MainActor
    func testHelperNonDestructiveDetectionAndDefaults() {
        if let helperExec = PrivilegeHelper.locateHelperExecutable() {
            #expect(FileManager.default.isExecutableFile(atPath: helperExec))
        }
        if let helperScript = PrivilegeHelper.locateHelperScript() {
            #expect(FileManager.default.isExecutableFile(atPath: helperScript))
        }
        let _ = PrivilegeHelper.isHelperDaemonInstalled

        let appState = AppStateTestHarness(startBackgroundTimers: false).appState
        #expect(appState.authorizationSummary == nil)
    }
}
