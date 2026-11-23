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
        VPNProfileInfo(name: "macos.ovpn", serverAddress: "vpn.campus.net")
    }

    public func detectConflicts(profile: VPNProfileInfo, currentLAN: String) -> [String] {
        mockConflicts
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

    public init() {}

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
    public var telemetrySent = false
    public var executedTools: [String] = []
    public var shouldThrowError = false
    public var mockAnalysis = LLMAnalysis(diagnosis: "Network optimal", recommendedActions: [])

    public init() {}

    public func sendTelemetry(report: NetworkTelemetryReport, endpoint: URL) async throws -> LLMAnalysis {
        if shouldThrowError {
            throw NSError(domain: "MockLLM", code: 500, userInfo: [NSLocalizedDescriptionKey: "LLM bridge offline"])
        }
        telemetrySent = true
        return mockAnalysis
    }

    public func executeTool(name: String, arguments: [String: Any]) async throws -> ToolResult {
        executedTools.append(name)
        return ToolResult(toolName: name, success: true, output: "Successfully executed \(name)")
    }
}

// MARK: - Mock Clipboard Watcher

public final class MockAppClipboardWatcher: ClipboardWatcherProtocol, @unchecked Sendable {
    public var isEnabled: Bool = true
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

    public func startMonitoring(interval: TimeInterval = 1.0) {}
    public func stopMonitoring() {}
}
