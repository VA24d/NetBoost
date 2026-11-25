import Foundation
import NetBoostCore
@testable import NetBoostApp

// MARK: - Mock Proxy Dispatcher

public final class MockAppProxyDispatcher: ProxyDispatcherProtocol, @unchecked Sendable {
    public var startCalled = false
    public var stopCalled = false
    public var startedPorts: [Int: String] = [:]
    public var shouldThrowError = false
    public var mockConnections: [ProxyConnectionInfo] = []

    public init() {}

    public func start(ports: [Int: String]) async throws {
        if shouldThrowError {
            throw NSError(domain: "MockProxy", code: 500, userInfo: [NSLocalizedDescriptionKey: "Proxy start failed"])
        }
        startCalled = true
        startedPorts = ports
    }

    public func stop() async throws {
        stopCalled = true
    }

    public var activeConnections: [ProxyConnectionInfo] {
        mockConnections
    }

    public func generateShellSnippet(port: Int) -> String {
        "export ALL_PROXY=socks5://127.0.0.1:\(port)"
    }
}

// MARK: - Mock VPN Controller

public final class MockAppVPNController: VPNControllerProtocol, @unchecked Sendable {
    public var connectCalled = false
    public var disconnectCalled = false
    public var lastProfileName: String?
    public var shouldThrowError = false
    public var mockStatus: VPNStatus = .disconnected
    public var mockConflicts: [String] = []
    public var mockParsedProfile: VPNProfileInfo?
    public var parseShouldThrowError = false
    public var lastConflictCheckedProfile: VPNProfileInfo?
    public var lastConflictCheckedLAN: String?

    public init() {}

    public func checkStatus(profileName: String) async -> VPNStatus {
        mockStatus
    }

    public func connect(profileName: String) async throws {
        if shouldThrowError {
            throw NSError(domain: "MockVPN", code: 500, userInfo: [NSLocalizedDescriptionKey: "VPN connect failed"])
        }
        connectCalled = true
        lastProfileName = profileName
        mockStatus = .connected
    }

    public func disconnect(profileName: String) async throws {
        disconnectCalled = true
        lastProfileName = profileName
        mockStatus = .disconnected
    }

    public func parseProfile(url: URL) throws -> VPNProfileInfo {
        if parseShouldThrowError {
            throw NSError(domain: "MockVPN", code: 422, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenVPN profile"])
        }
        return mockParsedProfile ?? VPNProfileInfo(name: "macos.ovpn", serverAddress: "vpn.campus.net")
    }

    public func detectConflicts(profile: VPNProfileInfo, currentLAN: String) -> [String] {
        lastConflictCheckedProfile = profile
        lastConflictCheckedLAN = currentLAN
        return mockConflicts
    }
}

// MARK: - Mock Download Manager

public final class MockAppDownloadManager: DownloadManagerProtocol, @unchecked Sendable {
    public var startDownloadCalled = false
    public var pauseCalled = false
    public var resumeCalled = false
    public var cancelCalled = false
    public var shouldThrowError = false
    public var lastDownloadURL: URL?
    public var lastChunksCount: Int = 0

    private var continuation: AsyncStream<DownloadTaskInfo>.Continuation?
    public let taskPublisher: AsyncStream<DownloadTaskInfo>

    public init() {
        var cont: AsyncStream<DownloadTaskInfo>.Continuation?
        self.taskPublisher = AsyncStream<DownloadTaskInfo> { c in
            cont = c
        }
        self.continuation = cont
    }

    public func emitTask(_ task: DownloadTaskInfo) {
        continuation?.yield(task)
    }

    public func startDownload(
        url: URL,
        destination: URL,
        chunksCount: Int,
        expectedChecksum: String?
    ) async throws -> DownloadTaskInfo {
        if shouldThrowError {
            throw NSError(domain: "MockDownloader", code: 500, userInfo: [NSLocalizedDescriptionKey: "Download failed"])
        }
        startDownloadCalled = true
        lastDownloadURL = url
        lastChunksCount = chunksCount

        var chunks: [DownloadChunkInfo] = []
        for i in 0..<chunksCount {
            let start = Int64(i * 1000)
            let end = Int64((i + 1) * 1000 - 1)
            chunks.append(DownloadChunkInfo(id: i, rangeStart: start, rangeEnd: end))
        }

        let task = DownloadTaskInfo(
            url: url,
            destinationURL: destination,
            totalBytes: 104_857_600,
            downloadedBytes: 0,
            chunks: chunks,
            status: .downloading,
            speedBytesPerSec: 5_242_880
        )
        return task
    }

    public func pauseDownload(id: UUID) async throws {
        pauseCalled = true
    }

    public func resumeDownload(id: UUID) async throws {
        resumeCalled = true
    }

    public func cancelDownload(id: UUID) async throws {
        cancelCalled = true
    }
}

// MARK: - Mock Campus Doctor

public final class MockAppCampusDoctor: CampusDoctorProtocol, @unchecked Sendable {
    public var executionLog: [String] = []
    public var mockProbeResults: [String: ProbeResult] = [:]
    public var mockCaptiveStatus: CaptivePortalStatus = .notDetected
    public var shouldThrowError = false

    public init() {}

    public func runFullDiagnostics() async -> NetworkTelemetryReport {
        executionLog.append("runFullDiagnostics")
        return NetworkTelemetryReport(
            timestamp: Date(),
            captivePortalStatus: mockCaptiveStatus,
            activeIssues: []
        )
    }

    public func pingTarget(host: String) async -> ProbeResult {
        mockProbeResults[host] ?? ProbeResult(targetHost: host, isReachable: true, latencyMs: 25.0)
    }

    public func checkCaptivePortal() async -> CaptivePortalStatus {
        mockCaptiveStatus
    }

    public func fixMTU(service: String, mtu: Int) async throws {
        executionLog.append("fixMTU_\(service)_\(mtu)")
        if shouldThrowError {
            throw NSError(domain: "MockDoctor", code: 500, userInfo: [NSLocalizedDescriptionKey: "MTU fix failed"])
        }
    }

    public func flushDNS() async throws {
        executionLog.append("flushDNS")
        if shouldThrowError {
            throw NSError(domain: "MockDoctor", code: 500, userInfo: [NSLocalizedDescriptionKey: "DNS flush failed"])
        }
    }

    public func flushARP() async throws {
        executionLog.append("flushARP")
        if shouldThrowError {
            throw NSError(domain: "MockDoctor", code: 500, userInfo: [NSLocalizedDescriptionKey: "ARP flush failed"])
        }
    }

    public func disableIPv6(service: String) async throws {
        executionLog.append("disableIPv6_\(service)")
    }

    public func reorderServices(ordered: [String]) async throws {
        executionLog.append("reorderServices_\(ordered.joined(separator: ","))")
    }
}

// MARK: - Mock Hotspot Controller

public final class MockAppHotspotController: HotspotControllerProtocol, @unchecked Sendable {
    public var startCalled = false
    public var stopCalled = false
    public var shouldThrowError = false
    public var mockClients: [HotspotClient] = []
    public var lastConfig: HotspotConfiguration?
    public var mockIsRadioBroadcasting: Bool = false

    public init() {}

    public func updateConfiguration(_ config: HotspotConfiguration) {
        lastConfig = config
    }

    public func isRadioBroadcasting() async -> Bool {
        mockIsRadioBroadcasting
    }

    public func startHotspot(configuration: HotspotConfiguration) async throws {
        lastConfig = configuration
        try await startHotspot(upstreamInterface: configuration.upstreamInterface, downstreamInterface: configuration.interfaceName)
    }

    public func startHotspot(upstreamInterface: String, downstreamInterface: String) async throws {
        if shouldThrowError {
            throw NSError(domain: "MockHotspot", code: 500, userInfo: [NSLocalizedDescriptionKey: "Hotspot start failed"])
        }
        startCalled = true
    }

    public func stopHotspot() async throws {
        stopCalled = true
    }

    public func connectedClients() async -> [HotspotClient] {
        mockClients
    }
}

// MARK: - Mock LLM Doctor Bridge

public final class MockAppLLMDoctorBridge: LLMDoctorBridgeProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var telemetrySent = false
    public var sendChatCalled = false
    public var lastChatMessage: String?
    public var lastChatReport: NetworkTelemetryReport?
    public var lastChatEndpoint: URL?
    public var executedTools: [String] = []
    public var appendedToolResults: [(toolCallId: String, name: String, output: String)] = []
    public var shouldThrowError = false
    public var mockAnalysis = LLMAnalysis(diagnosis: "Network optimal", recommendedActions: [])

    public init() {}

    public func sendTelemetry(report: NetworkTelemetryReport, endpoint: URL) async throws -> LLMAnalysis {
        let (fail, analysis) = lock.withLock { (shouldThrowError, mockAnalysis) }
        if fail {
            throw NSError(domain: "MockLLM", code: 500, userInfo: [NSLocalizedDescriptionKey: "LLM bridge offline"])
        }
        lock.withLock { telemetrySent = true }
        return analysis
    }

    public func sendChat(message: String, report: NetworkTelemetryReport?, endpoint: URL) async throws -> LLMAnalysis {
        let (fail, analysis) = lock.withLock { (shouldThrowError, mockAnalysis) }
        if fail {
            throw NSError(domain: "MockLLM", code: 500, userInfo: [NSLocalizedDescriptionKey: "LLM bridge offline"])
        }
        lock.withLock {
            sendChatCalled = true
            lastChatMessage = message
            lastChatReport = report
            lastChatEndpoint = endpoint
        }
        return analysis
    }

    public func appendToolResult(toolCallId: String, name: String, output: String) {
        lock.withLock {
            appendedToolResults.append((toolCallId: toolCallId, name: name, output: output))
        }
    }

    public func executeTool(name: String, arguments: [String: Any]) async throws -> ToolResult {
        lock.withLock { executedTools.append(name) }
        return ToolResult(toolName: name, success: true, output: "Successfully executed \(name)")
    }
}

// MARK: - Mock Clipboard Watcher

public final class MockAppClipboardWatcher: ClipboardWatcherProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var isEnabled: Bool = true
    public var startMonitoringCalled = false
    public var stopMonitoringCalled = false
    public var lastMonitoringInterval: TimeInterval?
    private var continuation: AsyncStream<URL>.Continuation?
    public let detectedURLs: AsyncStream<URL>

    public init() {
        var cont: AsyncStream<URL>.Continuation?
        self.detectedURLs = AsyncStream<URL> { c in
            cont = c
        }
        self.continuation = cont
    }

    public func emitURL(_ url: URL) {
        continuation?.yield(url)
    }

    public func evaluateClipboardContent(_ text: String) -> URL? {
        URL(string: text)
    }

    public func startMonitoring(interval: TimeInterval = 1.0) {
        lock.withLock {
            startMonitoringCalled = true
            lastMonitoringInterval = interval
        }
    }

    public func stopMonitoring() {
        lock.withLock {
            stopMonitoringCalled = true
        }
    }
}

// MARK: - Mock Network Sensor Providers & Route Pinning Test Harness

public final class MockAppPathMonitor: PathMonitorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (NetworkPathSnapshot) -> Void)?
    public var isStarted = false
    public var isCancelled = false
    private var _currentPath: NetworkPathSnapshot

    public var currentPath: NetworkPathSnapshot {
        lock.withLock { _currentPath }
    }

    public init(
        initialPath: NetworkPathSnapshot = NetworkPathSnapshot(
            status: .satisfied,
            availableInterfaceNames: ["en10", "en0"],
            primaryInterfaceType: .wiredEthernet
        )
    ) {
        self._currentPath = initialPath
    }

    public func start(onUpdate: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        let initial = lock.withLock { () -> NetworkPathSnapshot in
            isStarted = true
            handler = onUpdate
            return _currentPath
        }
        onUpdate(initial)
    }

    public func cancel() {
        lock.withLock {
            isCancelled = true
            handler = nil
        }
    }
}

public final class MockAppInterfaceProvider: NetworkInterfaceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _interfaces: [NetworkInterfaceInfo]

    public init(interfaces: [NetworkInterfaceInfo] = []) {
        self._interfaces = interfaces
    }

    public func fetchInterfaces() async -> [NetworkInterfaceInfo] {
        lock.withLock { _interfaces }
    }
}

@MainActor
public struct AppStateTestHarness {
    public let proxy: MockAppProxyDispatcher
    public let vpn: MockAppVPNController
    public let downloader: MockAppDownloadManager
    public let doctor: MockAppCampusDoctor
    public let hotspot: MockAppHotspotController
    public let llm: MockAppLLMDoctorBridge
    public let clipboard: MockAppClipboardWatcher
    public let pathMonitor: MockAppPathMonitor
    public let interfaceProvider: MockAppInterfaceProvider
    public let networkSensor: NetworkSensor
    public let routePinningEngine: RoutePinningEngine
    public let appState: AppState

    public init(
        startBackgroundTimers: Bool = false,
        gateway: String = RoutePinningEngine.defaultGateway,
        interface: String = RoutePinningEngine.defaultInterface,
        initialEnvironment: NetworkEnvironmentState = .defaultCampusLAN,
        interfaces: [NetworkInterfaceInfo] = []
    ) {
        self.proxy = MockAppProxyDispatcher()
        self.vpn = MockAppVPNController()
        self.downloader = MockAppDownloadManager()
        self.doctor = MockAppCampusDoctor()
        self.hotspot = MockAppHotspotController()
        self.llm = MockAppLLMDoctorBridge()
        self.clipboard = MockAppClipboardWatcher()
        self.pathMonitor = MockAppPathMonitor()
        self.interfaceProvider = MockAppInterfaceProvider(interfaces: interfaces)
        self.networkSensor = NetworkSensor(
            pathMonitor: pathMonitor,
            interfaceProvider: interfaceProvider,
            debounceInterval: 0.01,
            initialState: initialEnvironment
        )
        self.routePinningEngine = Self.makeRoutePinningEngine(gateway: gateway, interface: interface)
        self.appState = AppState(
            proxyDispatcher: proxy,
            vpnController: vpn,
            downloadManager: downloader,
            campusDoctor: doctor,
            hotspotController: hotspot,
            llmBridge: llm,
            pasteboardWatcher: clipboard,
            startBackgroundTimers: startBackgroundTimers,
            networkSensor: networkSensor,
            routePinningEngine: routePinningEngine
        )
    }

    public static func makeRoutePinningEngine(
        gateway: String = RoutePinningEngine.defaultGateway,
        interface: String = RoutePinningEngine.defaultInterface
    ) -> RoutePinningEngine {
        RoutePinningEngine(gateway: gateway, interface: interface)
    }

    public static func makeCampusInterfaceFixtures() -> [NetworkInterfaceInfo] {
        [
            NetworkInterfaceInfo(
                bsdName: "en10",
                displayName: "USB 10/100 LAN",
                ipAddresses: [IPAddress(address: "10.1.36.52", netmask: "255.255.252.0", prefixLength: 22)],
                gateway: "10.1.36.1",
                mtu: 1500,
                isPrimary: true,
                isUp: true
            ),
            NetworkInterfaceInfo(
                bsdName: "en0",
                displayName: "Wi-Fi",
                ipAddresses: [IPAddress(address: "192.168.1.42", netmask: "255.255.255.0", prefixLength: 24)],
                gateway: "192.168.1.1",
                mtu: 1500,
                isPrimary: false,
                isUp: true
            )
        ]
    }
}
