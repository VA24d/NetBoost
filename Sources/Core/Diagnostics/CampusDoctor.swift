import Foundation

/// Protocol governing campus network diagnostic probes and automated remediation.
public protocol CampusDoctorProtocol: Sendable {
    func runFullDiagnostics() async -> NetworkTelemetryReport
    func pingTarget(host: String) async -> ProbeResult
    func checkCaptivePortal() async -> CaptivePortalStatus
    func fixMTU(service: String, mtu: Int) async throws
    func flushDNS() async throws
    func flushARP() async throws
    func disableIPv6(service: String) async throws
    func reorderServices(ordered: [String]) async throws
    func executeBatchAutoFix(service: String, mtu: Int) async throws
    func isolatePrivateRelay(service: String) async throws
    func restorePrivateRelay(service: String) async throws
}

extension CampusDoctorProtocol {
    public func executeBatchAutoFix(service: String = "Wi-Fi", mtu: Int = 1280) async throws {
        try await fixMTU(service: service, mtu: mtu)
        try await flushDNS()
        try await flushARP()
    }

    public func isolatePrivateRelay(service: String = "USB 10/100 LAN") async throws {}
    public func restorePrivateRelay(service: String = "USB 10/100 LAN") async throws {}
}

/// Master network doctor coordinating latency probes, captive detection, MTU checks, and automated repairs.
public final class CampusDoctor: CampusDoctorProtocol, Sendable {

    public let latencyProbe: LatencyProbe
    public let captiveDetector: CaptivePortalDetector
    public let mtuManager: MTUManager
    public let repairRoutines: RepairRoutines
    public let serviceOrderManager: ServiceOrderManager
    public let interfaceProvider: NetworkInterfaceProvider

    public init(
        latencyProbe: LatencyProbe? = nil,
        captiveDetector: CaptivePortalDetector? = nil,
        mtuManager: MTUManager? = nil,
        repairRoutines: RepairRoutines? = nil,
        serviceOrderManager: ServiceOrderManager? = nil,
        interfaceProvider: NetworkInterfaceProvider? = nil
    ) {
        self.latencyProbe = latencyProbe ?? LatencyProbe()
        self.captiveDetector = captiveDetector ?? CaptivePortalDetector()
        self.mtuManager = mtuManager ?? MTUManager()
        self.repairRoutines = repairRoutines ?? RepairRoutines()
        self.serviceOrderManager = serviceOrderManager ?? ServiceOrderManager()
        self.interfaceProvider = interfaceProvider ?? SystemInterfaceProvider()
    }

    /// Performs a full diagnostic scan and produces an aggregated telemetry report with active issues.
    public func runFullDiagnostics() async -> NetworkTelemetryReport {
        let startTime = Date()

        let interfaces = await interfaceProvider.fetchInterfaces()
        let primaryInterface = interfaces.first(where: { $0.isPrimary }) ?? interfaces.first

        let gatewayTarget = primaryInterface?.gateway ?? LatencyProbe.localGateway
        let campusCoreTarget = LatencyProbe.campusCore

        async let gatewayProbe = latencyProbe.probe(target: gatewayTarget)
        async let campusCoreProbe = latencyProbe.probe(target: campusCoreTarget)
        async let turingProbe = latencyProbe.probe(target: LatencyProbe.turingHPC)
        async let googleProbe = latencyProbe.probe(target: LatencyProbe.google)
        async let claudeProbe = latencyProbe.probe(target: LatencyProbe.claude)
        async let captiveCheck = captiveDetector.evaluate()

        let (gw, core, turing, google, claude, captive) = await (
            gatewayProbe,
            campusCoreProbe,
            turingProbe,
            googleProbe,
            claudeProbe,
            (try? captiveCheck) ?? (.unknown, nil)
        )

        var externalRTTs: [String: Double] = [:]
        if turing.isReachable { externalRTTs[LatencyProbe.turingHPC] = turing.latencyMs }
        if google.isReachable { externalRTTs[LatencyProbe.google] = google.latencyMs }
        if claude.isReachable { externalRTTs[LatencyProbe.claude] = claude.latencyMs }

        var detectedIssues: [DetectedIssue] = []

        let isCaptiveDetected = captive.status == .detected || captive.status == .redirecting
        if let captiveIssue = captiveDetector.createIssueIfActive(status: captive.status, redirectURL: captive.redirectURL) {
            detectedIssues.append(captiveIssue)
        }

        for iface in interfaces {
            let isCellular = iface.bsdName == "en9" || iface.ipAddresses.contains(where: { $0.address.hasPrefix("172.20.10.") })
            if let mtuIssue = mtuManager.detectSuboptimalMTU(interface: iface, isCellular: isCellular) {
                detectedIssues.append(mtuIssue)
            }
        }

        if gw.packetLossPercent > 20.0 || (gw.isReachable && gw.latencyMs > 100.0) {
            detectedIssues.append(DetectedIssue(
                severity: .warning,
                title: "Elevated Gateway Latency or Packet Loss",
                description: "Local gateway \(gatewayTarget) latency is \(String(format: "%.1f", gw.latencyMs))ms with \(String(format: "%.0f", gw.packetLossPercent))% loss.",
                recommendedFixAction: "flush_arp",
                automatedFixAvailable: true
            ))
        }

        return NetworkTelemetryReport(
            timestamp: startTime,
            interfaces: interfaces,
            gatewayRTT: gw.isReachable ? gw.latencyMs : nil,
            campusCoreRTT: core.isReachable ? core.latencyMs : nil,
            externalEndpointsRTT: externalRTTs,
            captivePortalDetected: isCaptiveDetected,
            captivePortalStatus: captive.status,
            activeIssues: detectedIssues
        )
    }

    // MARK: - CampusDoctorProtocol Implementation

    public func pingTarget(host: String) async -> ProbeResult {
        await latencyProbe.probe(target: host)
    }

    public func checkCaptivePortal() async -> CaptivePortalStatus {
        await captiveDetector.checkStatus()
    }

    public func fixMTU(service: String, mtu: Int) async throws {
        try await mtuManager.setMTU(service: service, mtu: mtu)
        repairRoutines.recordEvent("Set MTU for \(service) to \(mtu)")
    }

    public func flushDNS() async throws {
        try await repairRoutines.flushDNS()
    }

    public func flushARP() async throws {
        try await repairRoutines.flushARP()
    }

    public func disableIPv6(service: String) async throws {
        try await repairRoutines.disableIPv6(service: service)
    }

    public func resetDNS(service: String) async throws {
        try await repairRoutines.resetDNS(service: service)
    }

    public func cleanProxies(service: String) async throws {
        try await repairRoutines.cleanProxies(service: service)
    }

    public func reorderServices(ordered: [String]) async throws {
        try await serviceOrderManager.reorderServices(orderedServices: ordered)
    }

    public func executeBatchAutoFix(service: String = "Wi-Fi", mtu: Int = 1280) async throws {
        try await repairRoutines.executeBatchAutoFix(service: service, mtu: mtu)
    }

    public func isolatePrivateRelay(service: String = "USB 10/100 LAN") async throws {
        try await repairRoutines.isolatePrivateRelay(for: service)
    }

    public func restorePrivateRelay(service: String = "USB 10/100 LAN") async throws {
        try await repairRoutines.restorePrivateRelay(for: service)
    }
}
