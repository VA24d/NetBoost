import Foundation
import SwiftUI
import NetBoostCore

// MARK: - Navigation Tabs

public enum AppNavigationTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard = "Dashboard"
    case hotspot = "Hotspot"
    case dispatcher = "Dispatcher"
    case vpn = "VPN & Routing"
    case accelerator = "Accelerator"
    case doctor = "Campus Doctor"
    case aiDoctor = "AI Doctor"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .hotspot: return "personalhotspot"
        case .dispatcher: return "arrow.triangle.branch"
        case .vpn: return "lock.shield"
        case .accelerator: return "bolt.horizontal"
        case .doctor: return "cross.case"
        case .aiDoctor: return "cpu"
        }
    }
}

// MARK: - Tool Execution Log Model

public struct ToolExecutionLog: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let toolName: String
    public let arguments: String
    public let success: Bool
    public let output: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        toolName: String,
        arguments: String,
        success: Bool,
        output: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.toolName = toolName
        self.arguments = arguments
        self.success = success
        self.output = output
    }
}

// MARK: - Customization Enums

public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case iconAndSpeed = "Icon + Speed"
    case compactSpeed = "Compact Speed"
    case minimalBadge = "Minimal Badge"

    public var id: String { rawValue }
}

public enum AppLogoStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case sapphireLightning = "Sapphire Bolt"
    case liquidWaveform = "Liquid Waveform"
    case networkCore = "Network Core"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .sapphireLightning: return "bolt.horizontal.circle.fill"
        case .liquidWaveform: return "waveform.path.ecg"
        case .networkCore: return "network"
        }
    }
}

// MARK: - AppState Central Coordinator

@MainActor
public final class AppState: ObservableObject {

    // MARK: - Navigation
    @Published public var selectedTab: AppNavigationTab = .dashboard

    // MARK: - Injected Protocol Controllers
    public let proxyDispatcher: any ProxyDispatcherProtocol
    public let vpnController: any VPNControllerProtocol
    public let downloadManager: any DownloadManagerProtocol
    public let campusDoctor: any CampusDoctorProtocol
    public let hotspotController: any HotspotControllerProtocol
    public let llmBridge: (any LLMDoctorBridgeProtocol)?
    public let pasteboardWatcher: any ClipboardWatcherProtocol

    // MARK: - Live Throughput & Header State
    @Published public var currentDownloadBps: Double = 0
    @Published public var currentUploadBps: Double = 0
    @Published public var smoothedDownloadBps: Double = 0
    @Published public var smoothedUploadBps: Double = 0
    @Published public var menuBarThroughputText: String = "↑ 0 B/s  ↓ 0 B/s"
    @Published public var activeEnvironment: NetworkEnvironmentState = .defaultCampusLAN
    @Published public var primaryInterface: String = "en10"
    @Published public var primaryInterfaceIP: String = "10.1.36.52"
    @Published public var activeStatePill: String = "Campus LAN (Direct)"
    @Published public var isAutoFixRunning: Bool = false
    @Published public var autoFixSummary: String? = nil

    // MARK: - Hotspot State
    @Published public var isHotspotActive: Bool = false
    @Published public var hotspotConfig: HotspotConfiguration = .default
    @Published public var hotspotSSID: String = "NetBoost-Hotspot" {
        didSet { hotspotConfig.ssid = hotspotSSID }
    }
    @Published public var hotspotPassword: String = "CampusNet2026!" {
        didSet { hotspotConfig.password = hotspotPassword }
    }
    @Published public var hotspotSecurityType: HotspotSecurityType = .wpa2Wpa3Transition {
        didSet { hotspotConfig.securityType = hotspotSecurityType }
    }
    @Published public var connectedClients: [HotspotClient] = []
    @Published public var upstreamInterface: String = "en10"
    @Published public var downstreamInterface: String = "en0"
    @Published public var hotspotError: String? = nil

    // MARK: - Customization Options (Logo & Status Bar)
    @Published public var menuBarIconStyle: MenuBarIconStyle = .iconAndSpeed
    @Published public var appLogoStyle: AppLogoStyle = .sapphireLightning

    // Private tracking for hardware interface throughput
    private var lastInterfaceIn: UInt64 = 0
    private var lastInterfaceOut: UInt64 = 0
    private var lastInterfaceSampleTime: Date = Date()

    public var canEnableHotspot: Bool {
        upstreamInterface == "en10" || activeEnvironment.isCampusLAN || (activeEnvironment.primaryInterface == "en10")
    }

    // MARK: - Proxy Dispatcher State
    @Published public var isProxyActive: Bool = false
    @Published public var proxyPorts: [Int: String] = [1080: "en10", 1081: "en0", 1082: "auto"]
    @Published public var activeConnections: [ProxyConnectionInfo] = []
    @Published public var copiedSnippetMessage: String? = nil
    @Published public var proxyError: String? = nil

    // MARK: - VPN & Routing State
    @Published public var vpnStatus: VPNStatus = .disconnected
    @Published public var activeVPNProfile: String = "macos.ovpn"
    @Published public var installedProfiles: [VPNServiceProfile] = []
    @Published public var parsedRoutes: [VPNRouteEntry] = []
    @Published public var routeConflicts: [String] = []
    @Published public var isVPNAutomationEnabled: Bool = true
    @Published public var networkServiceOrder: [String] = ["USB 10/100 LAN", "Wi-Fi", "Thunderbolt Bridge"]
    @Published public var lastVPNToggleTime: Date = Date.distantPast
    @Published public var vpnError: String? = nil

    // MARK: - Accelerator State
    @Published public var downloadURLInput: String = ""
    @Published public var detectedClipboardURL: URL? = nil
    @Published public var selectedChunkCount: Int = 8
    @Published public var expectedChecksum: String = ""
    @Published public var selectedChecksumAlgorithm: String = "SHA-256"
    @Published public var activeDownloadTask: DownloadTaskInfo? = nil
    @Published public var checksumMatchStatus: Bool? = nil
    @Published public var downloadError: String? = nil

    // MARK: - Campus Doctor State
    @Published public var endpointRTTs: [String: ProbeResult] = [:]
    @Published public var captivePortalStatus: CaptivePortalStatus = .notDetected
    @Published public var repairLogs: [String] = []
    @Published public var activeIssues: [DetectedIssue] = []

    public static let targetEndpoints: [String] = [
        "10.1.36.1",        // Switch Gateway
        "10.8.0.80",        // Campus Core
        "turing.iiit.ac.in", // Campus HPC Server
        "google.com",        // External DNS/Web
        "claude.com"         // External AI Cloud
    ]

    // MARK: - AI Doctor State
    @Published public var lmStudioEndpoint: URL = LLMDoctorBridge.defaultChatEndpoint
    @Published public var isLMStudioConnected: Bool = false
    @Published public var chatMessages: [ChatMessage] = []
    @Published public var isAIAnalyzing: Bool = false
    @Published public var latestAnalysis: LLMAnalysis? = nil
    @Published public var toolExecutionLogs: [ToolExecutionLog] = []

    // MARK: - Background Tasks
    private var throughputTimerTask: Task<Void, Never>?
    private var rttTimerTask: Task<Void, Never>?
    private var clipboardStreamTask: Task<Void, Never>?
    private var downloadStreamTask: Task<Void, Never>?

    // MARK: - Initializer

    public init(
        proxyDispatcher: any ProxyDispatcherProtocol = InterfaceProxyDispatcher(),
        vpnController: any VPNControllerProtocol = PassepartoutController(),
        downloadManager: any DownloadManagerProtocol = DownloadManager(),
        campusDoctor: any CampusDoctorProtocol = CampusDoctor(),
        hotspotController: any HotspotControllerProtocol = HotspotNATController(),
        llmBridge: (any LLMDoctorBridgeProtocol)? = LLMDoctorBridge(),
        pasteboardWatcher: any ClipboardWatcherProtocol = ClipboardWatcher(),
        startBackgroundTimers: Bool = true
    ) {
        self.proxyDispatcher = proxyDispatcher
        self.vpnController = vpnController
        self.downloadManager = downloadManager
        self.campusDoctor = campusDoctor
        self.hotspotController = hotspotController
        self.llmBridge = llmBridge
        self.pasteboardWatcher = pasteboardWatcher

        // Initialize active network state pill
        self.updateEnvironment(.defaultCampusLAN)

        if startBackgroundTimers {
            self.startBackgroundTasks()
        }
    }

    deinit {
        throughputTimerTask?.cancel()
        rttTimerTask?.cancel()
        clipboardStreamTask?.cancel()
        downloadStreamTask?.cancel()
    }

    // MARK: - Throughput & Speed Updates

    public func updateSpeeds(download: Double, upload: Double) {
        currentDownloadBps = download
        currentUploadBps = upload

        // EMA smoothing: alpha = 0.25 to prevent needle / label jitter
        smoothedDownloadBps = SpeedMetricsCalculator.updateEMA(
            previousSpeed: smoothedDownloadBps,
            instantaneousSpeed: download,
            alpha: 0.25
        )
        smoothedUploadBps = SpeedMetricsCalculator.updateEMA(
            previousSpeed: smoothedUploadBps,
            instantaneousSpeed: upload,
            alpha: 0.25
        )

        switch menuBarIconStyle {
        case .iconAndSpeed:
            menuBarThroughputText = SpeedFormatter.formatMenuBarThroughput(
                up: smoothedUploadBps,
                down: smoothedDownloadBps
            )
        case .compactSpeed:
            menuBarThroughputText = "↓ \(SpeedFormatter.formatCompact(smoothedDownloadBps)) ↑ \(SpeedFormatter.formatCompact(smoothedUploadBps))"
        case .minimalBadge:
            menuBarThroughputText = ""
        }
    }

    public func updateEnvironment(_ state: NetworkEnvironmentState) {
        activeEnvironment = state
        primaryInterface = state.primaryInterface ?? "en10"

        switch state {
        case .campusLAN(let iface, let ip, _, _):
            primaryInterface = iface
            primaryInterfaceIP = ip
            activeStatePill = "Campus LAN (Direct)"
        case .cellularHotspot(let iface, let ip, _, _):
            primaryInterface = iface
            primaryInterfaceIP = ip
            activeStatePill = "Cellular Hotspot (VPN)"
        case .externalWiFi(let iface, let ip, _, _):
            primaryInterface = iface
            primaryInterfaceIP = ip
            activeStatePill = "External Wi-Fi"
        case .disconnected:
            primaryInterfaceIP = "0.0.0.0"
            activeStatePill = "Offline"
        }
    }

    // MARK: - Quick Auto-Fix Action

    public func executeAutoFix() async {
        guard !isAutoFixRunning else { return }
        isAutoFixRunning = true
        autoFixSummary = nil
        appendRepairLog("⚡ Auto-Fix initiated: priority sequence MTU (1280) -> DNS -> ARP")

        do {
            // 1. Fix MTU to 1280 (eliminates bad record mac / TLS packet drops)
            appendRepairLog("Setting MTU to 1280 on Wi-Fi...")
            try await campusDoctor.fixMTU(service: "Wi-Fi", mtu: 1280)
            appendRepairLog("✓ MTU 1280 configured")

            // 2. Flush DNS cache
            appendRepairLog("Flushing mDNSResponder & dscacheutil...")
            try await campusDoctor.flushDNS()
            appendRepairLog("✓ DNS cache flushed")

            // 3. Flush ARP table
            appendRepairLog("Flushing kernel ARP cache...")
            try await campusDoctor.flushARP()
            appendRepairLog("✓ ARP cache cleared")

            autoFixSummary = "Auto-Fix Complete: MTU, DNS & ARP Restored"
            appendRepairLog("🎉 \(autoFixSummary!)")
        } catch {
            let errString = "Auto-Fix error: \(error.localizedDescription)"
            autoFixSummary = errString
            appendRepairLog("❌ \(errString)")
        }

        isAutoFixRunning = false
    }

    // MARK: - Hotspot Actions

    public func toggleHotspot() async throws {
        guard canEnableHotspot else {
            hotspotError = "Hotspot sharing requires active Wired Ethernet (en10)."
            appendRepairLog("⚠️ Hotspot toggle failed: en10 not active")
            return
        }

        if isHotspotActive {
            try await hotspotController.stopHotspot()
            isHotspotActive = false
            connectedClients = []
            hotspotConfig.isActive = false
            appendRepairLog("Hotspot stopped on \(downstreamInterface)")
        } else {
            try await hotspotController.startHotspot(
                upstreamInterface: upstreamInterface,
                downstreamInterface: downstreamInterface
            )
            isHotspotActive = true
            hotspotConfig.isActive = true
            connectedClients = await hotspotController.connectedClients()
            appendRepairLog("Hotspot started sharing \(upstreamInterface) -> \(downstreamInterface)")
        }
        hotspotError = nil
    }

    public func openSystemSharingSettings() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["x-apple.systempreferences:com.apple.Sharing-Settings.extension"]
        try? process.run()
    }

    public func refreshHotspotClients() async {
        guard isHotspotActive else { return }
        connectedClients = await hotspotController.connectedClients()
    }

    // MARK: - Proxy Dispatcher Actions

    public func toggleProxy() async throws {
        if isProxyActive {
            try await proxyDispatcher.stop()
            isProxyActive = false
            activeConnections = []
            appendRepairLog("Proxy Dispatcher stopped.")
        } else {
            try await proxyDispatcher.start(ports: proxyPorts)
            isProxyActive = true
            activeConnections = proxyDispatcher.activeConnections
            appendRepairLog("Proxy Dispatcher started on ports: \(proxyPorts.keys.sorted())")
        }
        proxyError = nil
    }

    public func generateShellSnippet(port: Int) -> String {
        let snippet = proxyDispatcher.generateShellSnippet(port: port)
        copiedSnippetMessage = "Copied snippet for port \(port)"
        return snippet
    }

    // MARK: - VPN Actions

    public func toggleVPN() async throws {
        // 0.5s toggle debounce check
        let now = Date()
        guard now.timeIntervalSince(lastVPNToggleTime) >= 0.5 else {
            appendRepairLog("VPN toggle debounced (< 0.5s)")
            return
        }
        lastVPNToggleTime = now

        if vpnStatus == .connected {
            try await vpnController.disconnect(profileName: activeVPNProfile)
            vpnStatus = .disconnected
            appendRepairLog("VPN disconnected: \(activeVPNProfile)")
        } else {
            try await vpnController.connect(profileName: activeVPNProfile)
            vpnStatus = .connected
            appendRepairLog("VPN connected: \(activeVPNProfile)")
        }
        vpnError = nil
    }

    public func checkRouteConflicts() {
        let sampleProfile = VPNProfileInfo(
            name: activeVPNProfile,
            serverAddress: "vpn.campus.net",
            routes: [
                VPNRouteEntry(destinationSubnet: "10.1.0.0", mask: "255.255.0.0"),
                VPNRouteEntry(destinationSubnet: "0.0.0.0", mask: "0.0.0.0")
            ]
        )
        routeConflicts = vpnController.detectConflicts(profile: sampleProfile, currentLAN: "10.1.36.0/22")
    }

    public func reorderServices(ordered: [String]) async throws {
        try await campusDoctor.reorderServices(ordered: ordered)
        networkServiceOrder = ordered
        appendRepairLog("Network service order updated: \(ordered.joined(separator: " -> "))")
    }

    // MARK: - Accelerator Actions

    public func startDownload() async throws {
        let trimmed = downloadURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              !host.isEmpty else {
            downloadError = "Invalid download URL: must begin with http:// or https:// and include a valid host"
            return
        }

        let filename = (url.lastPathComponent.isEmpty || url.lastPathComponent == "/") ? "download.bin" : url.lastPathComponent
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        let expected = expectedChecksum.isEmpty ? nil : expectedChecksum

        appendRepairLog("Starting accelerated download: \(url.absoluteString) with \(selectedChunkCount) chunks")
        activeDownloadTask = try await downloadManager.startDownload(
            url: url,
            destination: destination,
            chunksCount: selectedChunkCount,
            expectedChecksum: expected
        )
        downloadError = nil
    }

    public func pauseDownload() async throws {
        guard let task = activeDownloadTask else { return }
        try await downloadManager.pauseDownload(id: task.id)
        appendRepairLog("Download paused: \(task.id)")
    }

    public func resumeDownload() async throws {
        guard let task = activeDownloadTask else { return }
        try await downloadManager.resumeDownload(id: task.id)
        appendRepairLog("Download resumed: \(task.id)")
    }

    public func cancelDownload() async throws {
        guard let task = activeDownloadTask else { return }
        try await downloadManager.cancelDownload(id: task.id)
        activeDownloadTask = nil
        appendRepairLog("Download cancelled: \(task.id)")
    }

    public func verifyChecksum() async -> Bool {
        guard let task = activeDownloadTask, !expectedChecksum.isEmpty else {
            checksumMatchStatus = nil
            return false
        }
        let validator = ChecksumValidator()
        let match = (try? await validator.validate(fileURL: task.destinationURL, expectedChecksum: expectedChecksum)) ?? false
        checksumMatchStatus = match
        appendRepairLog("Checksum verification (\(selectedChecksumAlgorithm)): \(match ? "PASS" : "FAIL")")
        return match
    }

    // MARK: - Campus Doctor Actions

    public func runDiagnostics() async {
        appendRepairLog("Running full network diagnostics scan...")
        let report = await campusDoctor.runFullDiagnostics()
        activeIssues = report.activeIssues
        captivePortalStatus = report.captivePortalStatus

        // Probe the 5 endpoints
        for endpoint in Self.targetEndpoints {
            let res = await campusDoctor.pingTarget(host: endpoint)
            endpointRTTs[endpoint] = res
        }
        appendRepairLog("Diagnostics complete: \(activeIssues.count) issues detected")
    }

    public func manualFixMTU() async throws {
        appendRepairLog("Applying manual MTU 1280 fix...")
        try await campusDoctor.fixMTU(service: "Wi-Fi", mtu: 1280)
        appendRepairLog("✓ MTU 1280 set on Wi-Fi")
    }

    public func manualFlushDNS() async throws {
        appendRepairLog("Flushing DNS cache...")
        try await campusDoctor.flushDNS()
        appendRepairLog("✓ DNS flushed")
    }

    public func manualFlushARP() async throws {
        appendRepairLog("Flushing ARP table...")
        try await campusDoctor.flushARP()
        appendRepairLog("✓ ARP table flushed")
    }

    public func manualDisableIPv6() async throws {
        appendRepairLog("Disabling IPv6 on Wi-Fi...")
        try await campusDoctor.disableIPv6(service: "Wi-Fi")
        appendRepairLog("✓ IPv6 disabled")
    }

    public func manualResetDNS() async throws {
        appendRepairLog("Resetting DNS to DHCP defaults...")
        let repair = RepairRoutines()
        try await repair.resetDNS(service: "Wi-Fi")
        appendRepairLog("✓ DNS reset to DHCP defaults")
    }

    public func clearRepairLogs() {
        repairLogs.removeAll()
    }

    public func appendRepairLog(_ entry: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        repairLogs.append("[\(timestamp)] \(entry)")
        if repairLogs.count > 200 {
            repairLogs.removeFirst(repairLogs.count - 200)
        }
    }

    // MARK: - AI Doctor Actions

    public func sendChatMessage(text: String) async {
        guard !text.isEmpty else { return }
        chatMessages.append(ChatMessage(role: "user", content: text))
        isAIAnalyzing = true

        guard let bridge = llmBridge else {
            chatMessages.append(ChatMessage(role: "assistant", content: "LLM Bridge is not configured."))
            isAIAnalyzing = false
            return
        }

        do {
            let report = await campusDoctor.runFullDiagnostics()
            let analysis = try await bridge.sendTelemetry(report: report, endpoint: lmStudioEndpoint)
            latestAnalysis = analysis
            chatMessages.append(ChatMessage(role: "assistant", content: analysis.diagnosis))
            isLMStudioConnected = true
        } catch {
            isLMStudioConnected = false
            chatMessages.append(ChatMessage(
                role: "assistant",
                content: "Unable to reach LM Studio at \(lmStudioEndpoint.absoluteString). Please ensure LM Studio local server is started on port 1234. Error: \(error.localizedDescription)"
            ))
        }

        isAIAnalyzing = false
    }

    public func runDiagnosticsAndAnalyze() async {
        isAIAnalyzing = true
        appendRepairLog("Sending telemetry report to AI Doctor...")

        guard let bridge = llmBridge else {
            appendRepairLog("❌ LLM Bridge not available")
            isAIAnalyzing = false
            return
        }

        do {
            let report = await campusDoctor.runFullDiagnostics()
            let analysis = try await bridge.sendTelemetry(report: report, endpoint: lmStudioEndpoint)
            latestAnalysis = analysis
            isLMStudioConnected = true
            appendRepairLog("AI Analysis received: \(analysis.diagnosis)")
        } catch {
            isLMStudioConnected = false
            appendRepairLog("❌ AI Doctor offline: \(error.localizedDescription)")
        }

        isAIAnalyzing = false
    }

    nonisolated private static func runTool(
        bridge: any LLMDoctorBridgeProtocol,
        name: String,
        arguments: [String: String]
    ) async throws -> ToolResult {
        let anyArgs: [String: Any] = arguments
        return try await bridge.executeTool(name: name, arguments: anyArgs)
    }

    public func approveAndExecuteTool(name: String, arguments: [String: String]) async throws -> ToolResult {
        guard let bridge = llmBridge else {
            throw NSError(domain: "NetBoost", code: 404, userInfo: [NSLocalizedDescriptionKey: "LLM Bridge unavailable"])
        }

        appendRepairLog("🤖 Executing AI approved tool: \(name)")
        let result = try await Self.runTool(bridge: bridge, name: name, arguments: arguments)

        let argsString = arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        toolExecutionLogs.append(
            ToolExecutionLog(
                toolName: name,
                arguments: argsString,
                success: result.success,
                output: result.output
            )
        )

        appendRepairLog("Tool [\(name)] output: \(result.output)")
        return result
    }

    // MARK: - Background Tasks Implementation

    public func startBackgroundTasks() {
        // 1. Throughput Polling (1 second) with EMA smoothing & hardware byte counters
        throughputTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self else { break }
                await MainActor.run {
                    let now = Date()
                    let dt = max(0.2, now.timeIntervalSince(self.lastInterfaceSampleTime))
                    self.lastInterfaceSampleTime = now

                    let counters = DarwinSocketHelper.getInterfaceBytes(for: self.primaryInterface.isEmpty ? nil : self.primaryInterface)

                    var instDown: Double = 0
                    var instUp: Double = 0

                    if self.isProxyActive {
                        let connections = self.proxyDispatcher.activeConnections
                        var bytesUp: Double = 0
                        var bytesDown: Double = 0
                        for conn in connections {
                            bytesUp += Double(conn.bytesWritten)
                            bytesDown += Double(conn.bytesRead)
                        }
                        instDown = bytesDown
                        instUp = bytesUp
                    } else if let task = self.activeDownloadTask {
                        instDown = task.speedBytesPerSec
                        instUp = 0
                    } else if self.lastInterfaceIn > 0 && counters.inputBytes >= self.lastInterfaceIn {
                        let deltaIn = counters.inputBytes - self.lastInterfaceIn
                        let deltaOut = counters.outputBytes >= self.lastInterfaceOut ? (counters.outputBytes - self.lastInterfaceOut) : 0
                        instDown = Double(deltaIn) / dt
                        instUp = Double(deltaOut) / dt
                    }

                    self.lastInterfaceIn = counters.inputBytes
                    self.lastInterfaceOut = counters.outputBytes

                    self.updateSpeeds(download: instDown, upload: instUp)
                }
            }
        }

        // 2. RTT Probe Loop (2 seconds) across 5 endpoints
        rttTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self = self else { break }
                for endpoint in Self.targetEndpoints {
                    let result = await self.campusDoctor.pingTarget(host: endpoint)
                    await MainActor.run {
                        self.endpointRTTs[endpoint] = result
                    }
                }
            }
        }

        // 3. Clipboard URL Watcher Stream
        clipboardStreamTask = Task { [weak self] in
            guard let self = self else { return }
            for await url in self.pasteboardWatcher.detectedURLs {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.detectedClipboardURL = url
                    self.appendRepairLog("📋 Clipboard detected download URL: \(url.absoluteString)")
                }
            }
        }

        // 4. Download Task Info Stream
        downloadStreamTask = Task { [weak self] in
            guard let self = self else { return }
            for await task in self.downloadManager.taskPublisher {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.activeDownloadTask = task
                }
            }
        }
    }

    public func stopBackgroundTasks() {
        throughputTimerTask?.cancel()
        throughputTimerTask = nil
        rttTimerTask?.cancel()
        rttTimerTask = nil
        clipboardStreamTask?.cancel()
        clipboardStreamTask = nil
        downloadStreamTask?.cancel()
        downloadStreamTask = nil
    }
}
