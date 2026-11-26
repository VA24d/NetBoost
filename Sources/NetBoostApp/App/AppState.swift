import AppKit
import Darwin
import Foundation
import NetBoostCore
import SwiftUI

// MARK: - Global Reactive State Store

@MainActor
public final class AppState: ObservableObject {

    // Navigation
    @Published public var selectedTab: AppNavigationTab = .dashboard

    // Injected Services
    public let proxyDispatcher: any ProxyDispatcherProtocol
    public let vpnController: any VPNControllerProtocol
    public let downloadManager: any DownloadManagerProtocol
    public let campusDoctor: any CampusDoctorProtocol
    public let hotspotController: any HotspotControllerProtocol
    public let llmBridge: (any LLMDoctorBridgeProtocol)?
    public let pasteboardWatcher: any ClipboardWatcherProtocol
    internal let injectedNetworkSensor: NetworkSensor?
    internal let routePinningEngine: RoutePinningEngine
    internal let serviceOrderManager: ServiceOrderManager
    internal var activeNetworkSensor: NetworkSensor?
    internal var vpnRuleEngine: VPNRuleEngine?

    // Live Throughput & Header State
    @Published public var currentDownloadBps: Double = 0
    @Published public var currentUploadBps: Double = 0
    @Published public var smoothedDownloadBps: Double = 0
    @Published public var smoothedUploadBps: Double = 0
    @Published public var menuBarThroughputText: String = "↑ 0 B/s  ↓ 0 B/s"
    @Published public var activeEnvironment: NetworkEnvironmentState = .defaultCampusLAN
    @Published public var primaryInterface: String = "en10"
    @Published public var primaryInterfaceIP: String = "10.1.36.52"
    @Published public var activeStatePill: String = "Wired LAN (Direct)"
    @Published public var isAutoFixRunning: Bool = false
    @Published public var autoFixSummary: String? = nil

    // Hardware Interfaces & Telemetry
    @Published public var hardwareInterfaces: [NetworkInterfaceInfo] = []

    // Hotspot State
    @Published public var isHotspotActive: Bool = false
    @Published public var isRadioBroadcasting: Bool = false
    @Published public var hotspotConfig: HotspotConfiguration = .default
    @Published public var hotspotSSID: String = "NetBoost" {
        didSet {
            hotspotConfig.ssid = hotspotSSID
            hotspotController.updateConfiguration(hotspotConfig)
        }
    }
    @Published public var hotspotPassword: String = "12345678" {
        didSet {
            hotspotConfig.password = hotspotPassword
            hotspotController.updateConfiguration(hotspotConfig)
        }
    }
    @Published public var hotspotSecurityType: HotspotSecurityType = .wpa2Wpa3Transition {
        didSet {
            hotspotConfig.securityType = hotspotSecurityType
            hotspotController.updateConfiguration(hotspotConfig)
        }
    }
    @Published public var connectedClients: [HotspotClient] = []
    @Published public var upstreamInterface: String = "en10"
    @Published public var downstreamInterface: String = "en0"
    @Published public var hotspotError: String? = nil
    @Published public internal(set) var isWiFiConnectedToExternalNetwork: Bool = false
    @Published public internal(set) var dot1XProtectedInterfaces: Set<String> = []
    internal var userSelectedUpstreamInterface: String? = nil

    public var isUpstreamProtectedBy8021X: Bool {
        dot1XProtectedInterfaces.contains(upstreamInterface)
    }

    public var activeWiredInterface: NetworkInterfaceInfo? {
        let wiredCandidates = hardwareInterfaces.filter { iface in
            guard let ip = iface.ipv4Address,
                  !ip.hasPrefix("169.254."),
                  !ip.hasPrefix("127.") else {
                return false
            }
            let lower = iface.bsdName.lowercased()
            let displayLower = iface.displayName.lowercased()
            return iface.isUp
                && iface.bsdName != "en0"
                && iface.bsdName != "en9"
                && lower.hasPrefix("en")
                && HotspotNATController.isEligibleHotspotInterface(iface.bsdName)
                && !displayLower.contains("iphone")
        }
        if let upstreamMatch = wiredCandidates.first(where: { $0.bsdName == upstreamInterface }) {
            return upstreamMatch
        }
        if let primaryMatch = wiredCandidates.first(where: { $0.isPrimary }) {
            return primaryMatch
        }
        if let en10Match = wiredCandidates.first(where: { $0.bsdName == "en10" }) {
            return en10Match
        }
        if let firstWired = wiredCandidates.sorted(by: {
            $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending
        }).first {
            return firstWired
        }
        if hardwareInterfaces.isEmpty, activeEnvironment.isCampusLAN {
            let bsd = primaryInterface.isEmpty ? "en10" : primaryInterface
            let ip = primaryInterfaceIP.isEmpty ? "0.0.0.0" : primaryInterfaceIP
            return NetworkInterfaceInfo(
                bsdName: bsd,
                displayName: "Wired Ethernet",
                ipAddresses: [IPAddress(address: ip)],
                isPrimary: true,
                isUp: true
            )
        }
        return nil
    }

    public var menuBarWiredLabel: String {
        activeWiredInterface?.bsdName ?? "No LAN"
    }

    public var menuBarLabelText: String {
        let speed = menuBarThroughputText
        switch menuBarIconStyle {
        case .iconAndSpeed:
            let formatted = speed.isEmpty
                ? SpeedFormatter.formatMenuBarThroughput(up: smoothedUploadBps, down: smoothedDownloadBps)
                : speed
            return "\(menuBarWiredLabel) · \(formatted)"
        case .compactSpeed:
            let compact = speed.isEmpty
                ? "↓ \(SpeedFormatter.formatCompact(smoothedDownloadBps)) ↑ \(SpeedFormatter.formatCompact(smoothedUploadBps))"
                : speed
            return "\(menuBarWiredLabel) · \(compact)"
        case .minimalBadge:
            return activeWiredInterface?.bsdName ?? ""
        }
    }

    public var shareableUpstreamInterfaces: [NetworkInterfaceInfo] {
        let protected = dot1XProtectedInterfaces
        return hardwareInterfaces
            .filter { iface in
                iface.isUp
                    && iface.bsdName != "en0"
                    && iface.bsdName != downstreamInterface
                    && iface.bsdName.hasPrefix("en")
                    && iface.ipv4Address != nil
                    && HotspotNATController.isEligibleHotspotInterface(iface.bsdName)
            }
            .sorted { lhs, rhs in
                let lhsProtected = protected.contains(lhs.bsdName)
                let rhsProtected = protected.contains(rhs.bsdName)
                if lhsProtected != rhsProtected { return !lhsProtected }
                if (lhs.bsdName == "en10") != (rhs.bsdName == "en10") {
                    return lhs.bsdName == "en10"
                }
                return lhs.bsdName.localizedStandardCompare(rhs.bsdName) == .orderedAscending
            }
    }

    public func selectUpstreamInterface(_ bsdName: String) {
        userSelectedUpstreamInterface = bsdName
        upstreamInterface = bsdName
    }

    // Appearance Preferences
    @Published public var menuBarIconStyle: MenuBarIconStyle = .iconAndSpeed
    @Published public var appLogoStyle: AppLogoStyle = .sapphireLightning

    // One-Time Persistent Privilege Helper Authorization
    @Published public var isAuthorized: Bool = PrivilegeHelper.isAuthorized
    @Published public var authorizationSummary: String? = nil

    // Hardware byte counters for EMA throughput
    internal var lastInterfaceIn: UInt64 = 0
    internal var lastInterfaceOut: UInt64 = 0
    internal var lastInterfaceSampleTime: Date = Date()
    internal var lastTrackedInterface: String? = nil

    // Proxy Dispatcher & Route Pinning State
    @Published public var isProxyActive: Bool = false
    @Published public var proxyPorts: [Int: String] = [1080: "en10", 1081: "en0", 1082: "auto"]
    @Published public var activeConnections: [ProxyConnectionInfo] = []
    @Published public var proxyTotalBytesRead: Int64 = 0
    @Published public var proxyTotalBytesWritten: Int64 = 0
    @Published public var copiedSnippetMessage: String? = nil
    @Published public var proxyError: String? = nil
    @Published public var pinnedRoutes: [PinnedRoute] = []
    @Published public var routePinResultMessage: String? = nil
    @Published public var cliTaskOutput: String = ""
    @Published public var isRunningCLITask: Bool = false

    // VPN & Service Ordering State
    @Published public var vpnStatus: VPNStatus = .disconnected
    @Published public var activeVPNProfile: String = "macos.ovpn"
    @Published public var installedProfiles: [VPNServiceProfile] = []
    @Published public var loadedProfileInfo: VPNProfileInfo? = nil
    @Published public var parsedRoutes: [VPNRouteEntry] = []
    @Published public var routeConflicts: [String] = []
    @Published public var conflictReport: RouteConflictReport? = nil
    @Published public var isVPNAutomationEnabled: Bool = true {
        didSet {
            vpnRuleEngine?.updatePolicy(VPNRulePolicy(autoConnectEnabled: isVPNAutomationEnabled, targetProfileName: activeVPNProfile))
        }
    }
    @Published public var networkServiceOrder: [String] = ["USB 10/100 LAN", "Wi-Fi", "Thunderbolt Bridge"]
    @Published public var serviceEntries: [ServiceOrderManager.ServiceEntry] = []
    @Published public var lastVPNToggleTime: Date = Date.distantPast
    @Published public var vpnError: String? = nil

    // Download Accelerator State
    @Published public var downloadURLInput: String = ""
    @Published public var detectedClipboardURL: URL? = nil
    @Published public var selectedChunkCount: Int = 8
    @Published public var expectedChecksum: String = ""
    @Published public var selectedChecksumAlgorithm: String = "SHA-256"
    @Published public var downloadDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    @Published public var activeDownloadTask: DownloadTaskInfo? = nil
    @Published public var checksumMatchStatus: Bool? = nil
    @Published public var downloadError: String? = nil

    // Campus Doctor State
    @Published public var selectedRepairService: String = "Wi-Fi"
    @Published public var availableServices: [String] = ["Wi-Fi", "USB 10/100 LAN"]
    @Published public var isPrivateRelayIsolated: Bool = false
    @Published public var endpointRTTs: [String: ProbeResult] = [:]
    @Published public var captivePortalStatus: CaptivePortalStatus = .notDetected
    @Published public var tracerouteTarget: String = "turing.iiit.ac.in"
    @Published public var tracerouteHops: [String] = []
    @Published public var isTracerouting: Bool = false
    @Published public var repairLogs: [String] = []
    @Published public var activeIssues: [DetectedIssue] = []

    public static let targetEndpoints: [String] = [
        "10.1.36.1",
        "10.8.0.80",
        "turing.iiit.ac.in",
        "google.com",
        "claude.com"
    ]

    // AI Doctor State
    @Published public var lmStudioEndpoint: URL = LLMDoctorBridge.defaultChatEndpoint
    @Published public var lmStudioEndpointString: String = LLMDoctorBridge.defaultChatEndpoint.absoluteString
    @Published public var availableAIModels: [String] = []
    @Published public var selectedAIModel: String = "" {
        didSet {
            (llmBridge as? LLMDoctorBridge)?.selectedModel = selectedAIModel.isEmpty ? nil : selectedAIModel
        }
    }
    @Published public var isLMStudioConnected: Bool = false
    @Published public var chatMessages: [ChatMessage] = []
    @Published public var isAIAnalyzing: Bool = false
    @Published public var latestAnalysis: LLMAnalysis? = nil
    @Published public var toolExecutionLogs: [ToolExecutionLog] = []

    // Background Tasks
    internal var throughputTimerTask: Task<Void, Never>?
    internal var rttTimerTask: Task<Void, Never>?
    internal var clipboardStreamTask: Task<Void, Never>?
    internal var downloadStreamTask: Task<Void, Never>?
    internal var sensorStreamTask: Task<Void, Never>?
    internal var vpnRuleTask: Task<Void, Never>?
    internal var bootstrapTask: Task<Void, Never>?

    // MARK: - Initializer

    public init(
        proxyDispatcher: any ProxyDispatcherProtocol = InterfaceProxyDispatcher(),
        vpnController: any VPNControllerProtocol = PassepartoutController(),
        downloadManager: any DownloadManagerProtocol = DownloadManager(),
        campusDoctor: any CampusDoctorProtocol = CampusDoctor(),
        hotspotController: any HotspotControllerProtocol = HotspotNATController(),
        llmBridge: (any LLMDoctorBridgeProtocol)? = LLMDoctorBridge(),
        pasteboardWatcher: any ClipboardWatcherProtocol = ClipboardWatcher(),
        startBackgroundTimers: Bool = true,
        networkSensor: NetworkSensor? = nil,
        routePinningEngine: RoutePinningEngine? = nil,
        serviceOrderManager: ServiceOrderManager? = nil
    ) {
        self.proxyDispatcher = proxyDispatcher
        self.vpnController = vpnController
        self.downloadManager = downloadManager
        self.campusDoctor = campusDoctor
        self.hotspotController = hotspotController
        self.llmBridge = llmBridge
        self.pasteboardWatcher = pasteboardWatcher
        self.injectedNetworkSensor = networkSensor
        self.routePinningEngine = routePinningEngine ?? RoutePinningEngine()
        self.serviceOrderManager = serviceOrderManager ?? ServiceOrderManager()

        self.updateEnvironment(.defaultCampusLAN)

        if startBackgroundTimers {
            Task { [weak self] in
                await self?.refreshAuthorizationStatus()
            }
            self.startBackgroundTasks()
        }
    }

    deinit {
        throughputTimerTask?.cancel()
        rttTimerTask?.cancel()
        clipboardStreamTask?.cancel()
        downloadStreamTask?.cancel()
        sensorStreamTask?.cancel()
        vpnRuleTask?.cancel()
        bootstrapTask?.cancel()
    }

    // MARK: - Authorization & Network State

    nonisolated internal static func checkExternalWiFiConnected(downstream: String) -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }

        let requiredFlags = UInt32(IFF_UP | IFF_RUNNING)
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let flags = ptr.pointee.ifa_flags
            let name = String(cString: ptr.pointee.ifa_name)
            if name == downstream,
               (flags & requiredFlags) == requiredFlags,
               let addr = ptr.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = hostname.withUnsafeBufferPointer { buf in
                        guard let base = buf.baseAddress else { return "" }
                        return String(cString: base)
                    }
                    if !ip.isEmpty
                        && ip != "192.168.2.1"
                        && ip != "192.168.3.1"
                        && !ip.hasPrefix("127.")
                        && !ip.hasPrefix("169.254.") {
                        return true
                    }
                }
            }
            cursor = ptr.pointee.ifa_next
        }
        return false
    }

    public func syncAuthorizationStatus() {
        Task { [weak self] in
            await self?.refreshAuthorizationStatus()
        }
    }

    public func refreshAuthorizationStatus() async {
        let ready = await PrivilegeHelper.syncAuthorizationFromDaemonAsync()
        self.isAuthorized = ready || PrivilegeHelper.isRoot
        if ready {
            self.authorizationSummary = "Authorized"
        }
    }

    public func requestUpfrontAuthorization() async {
        do {
            let granted = try await PrivilegeHelper.requestAuthorization()
            self.isAuthorized = granted
            if granted {
                self.authorizationSummary = "Authorized"
                appendRepairLog("Privileged helper daemon authorized persistently")
            }
        } catch PrivilegeError.elevationDenied {
            self.isAuthorized = false
            self.authorizationSummary = "Authorization Cancelled"
            appendRepairLog("Administrator authorization cancelled by user")
        } catch {
            self.isAuthorized = false
            self.authorizationSummary = "Authorization Failed"
            appendRepairLog("Authorization error: \(error.localizedDescription)")
        }
    }

    public func uninstallPrivilegedHelper() async {
        do {
            try await PrivilegeHelper.uninstallDaemon()
            self.isAuthorized = PrivilegeHelper.isRoot
            self.authorizationSummary = nil
            appendRepairLog("Privileged helper daemon uninstalled")
        } catch {
            appendRepairLog("Helper uninstall failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Throughput & Environment Updates

    public func updateSpeeds(download: Double, upload: Double) {
        currentDownloadBps = download
        currentUploadBps = upload

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
            activeStatePill = "Wired LAN (Direct)"
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

    public func refreshHardwareInterfaces() async {
        let interfaces = await SystemInterfaceProvider().fetchInterfaces()
        let targetDownstream = downstreamInterface
        let (detected8021X, externalWiFi) = await Task.detached(priority: .utility) {
            (
                HotspotNATController.detectActive8021XInterfaces(),
                Self.checkExternalWiFiConnected(downstream: targetDownstream)
            )
        }.value

        hardwareInterfaces = interfaces
        dot1XProtectedInterfaces = detected8021X

        let activeUp = interfaces.filter { $0.isUp }
        let physicalUp = activeUp.filter { iface in
            let lower = iface.bsdName.lowercased()
            guard iface.bsdName != "en0", iface.ipv4Address != nil else { return false }
            return HotspotNATController.isEligibleHotspotInterface(iface.bsdName)
                && !lower.hasPrefix("ipsec")
                && !lower.hasPrefix("ppp")
        }

        let currentIsActiveEligible = physicalUp.contains(where: { $0.bsdName == upstreamInterface })
        let currentIs8021XLocked = detected8021X.contains(upstreamInterface)
        let isUserChoiceActive = userSelectedUpstreamInterface == upstreamInterface && currentIsActiveEligible
        if let preferred = HotspotNATController.selectPreferredUpstreamInterface(
            from: physicalUp,
            dot1XProtected: detected8021X
        ) {
            if !currentIsActiveEligible || (!isUserChoiceActive && currentIs8021XLocked && !detected8021X.contains(preferred)) {
                upstreamInterface = preferred
            }
        }
        if activeUp.contains(where: { $0.bsdName == "en0" }) {
            downstreamInterface = "en0"
        }

        isWiFiConnectedToExternalNetwork = externalWiFi
    }
}
