import Foundation
import NetBoostCore

@MainActor
extension AppState {

    // MARK: - Quick Auto-Fix & Campus Doctor Actions

    public func executeAutoFix() async {
        guard !isAutoFixRunning else { return }
        isAutoFixRunning = true
        autoFixSummary = nil
        let targetService = selectedRepairService
        appendRepairLog("Auto-Fix initiated on \(targetService): MTU 1280, DNS flush, ARP clear")

        do {
            try await campusDoctor.executeBatchAutoFix(service: targetService, mtu: 1280)
            await refreshAuthorizationStatus()
            autoFixSummary = "Auto-Fix Complete: MTU, DNS & ARP Restored"
            appendRepairLog(autoFixSummary ?? "Auto-Fix Complete")
        } catch PrivilegeError.elevationDenied {
            let errString = "Auto-Fix cancelled: Administrator elevation was denied"
            autoFixSummary = "Auto-Fix error: \(errString)"
            appendRepairLog(autoFixSummary ?? errString)
        } catch {
            let errString = "Auto-Fix error: \(error.localizedDescription)"
            autoFixSummary = errString
            appendRepairLog(errString)
        }

        isAutoFixRunning = false
    }

    public func runDiagnostics() async {
        appendRepairLog("Running network diagnostics scan...")
        let report = await campusDoctor.runFullDiagnostics()
        activeIssues = report.activeIssues
        captivePortalStatus = report.captivePortalStatus

        let results = await probeEndpointsConcurrently()
        for (endpoint, result) in results {
            endpointRTTs[endpoint] = result
        }
        await refreshPrivateRelayStatus()
        appendRepairLog("Diagnostics complete: \(activeIssues.count) issues detected")
    }

    internal func probeEndpointsConcurrently() async -> [(String, ProbeResult)] {
        let doctor = self.campusDoctor
        return await withTaskGroup(of: (String, ProbeResult).self) { group in
            for endpoint in Self.targetEndpoints {
                group.addTask {
                    let result = await doctor.pingTarget(host: endpoint)
                    return (endpoint, result)
                }
            }
            var collected: [(String, ProbeResult)] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }
    }

    public func refreshPrivateRelayStatus() async {
        let isolated = await RepairRoutines().isPrivateRelayIsolated(service: selectedRepairService)
        isPrivateRelayIsolated = isolated
    }

    public func togglePrivateRelayIsolation() async throws {
        if isPrivateRelayIsolated {
            try await campusDoctor.restorePrivateRelay(service: selectedRepairService)
            isPrivateRelayIsolated = false
            appendRepairLog("Private Relay restored on \(selectedRepairService)")
        } else {
            try await campusDoctor.isolatePrivateRelay(service: selectedRepairService)
            isPrivateRelayIsolated = true
            appendRepairLog("Private Relay isolated on \(selectedRepairService)")
        }
        await refreshAuthorizationStatus()
    }

    public func runTraceroute() async {
        let target = tracerouteTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !isTracerouting else { return }
        isTracerouting = true
        let hops = await LatencyProbe().traceroute(target: target, maxHops: 12)
        tracerouteHops = hops
        isTracerouting = false
    }

    private func runRepairAction(
        startMessage: String,
        completeMessage: String,
        operation: () async throws -> Void
    ) async throws {
        appendRepairLog(startMessage)
        try await operation()
        await refreshAuthorizationStatus()
        appendRepairLog(completeMessage)
    }

    public func manualFixMTU() async throws {
        try await runRepairAction(
            startMessage: "Applying MTU 1280 on \(selectedRepairService)...",
            completeMessage: "MTU 1280 set on \(selectedRepairService)"
        ) {
            try await campusDoctor.fixMTU(service: selectedRepairService, mtu: 1280)
        }
    }

    public func manualFlushDNS() async throws {
        try await runRepairAction(
            startMessage: "Flushing DNS cache...",
            completeMessage: "DNS cache flushed"
        ) {
            try await campusDoctor.flushDNS()
        }
    }

    public func manualFlushARP() async throws {
        try await runRepairAction(
            startMessage: "Flushing ARP table...",
            completeMessage: "ARP table flushed"
        ) {
            try await campusDoctor.flushARP()
        }
    }

    public func manualDisableIPv6() async throws {
        try await runRepairAction(
            startMessage: "Disabling IPv6 on \(selectedRepairService)...",
            completeMessage: "IPv6 disabled on \(selectedRepairService)"
        ) {
            try await campusDoctor.disableIPv6(service: selectedRepairService)
        }
    }

    public func manualEnableIPv6() async throws {
        try await runRepairAction(
            startMessage: "Restoring automatic IPv6 on \(selectedRepairService)...",
            completeMessage: "IPv6 restored on \(selectedRepairService)"
        ) {
            try await RepairRoutines().enableIPv6(service: selectedRepairService)
        }
    }

    public func manualResetDNS() async throws {
        try await runRepairAction(
            startMessage: "Resetting DNS on \(selectedRepairService) to DHCP defaults...",
            completeMessage: "DNS reset on \(selectedRepairService)"
        ) {
            try await RepairRoutines().resetDNS(service: selectedRepairService)
        }
    }

    public func manualCleanProxies() async throws {
        try await runRepairAction(
            startMessage: "Clearing system proxies on \(selectedRepairService)...",
            completeMessage: "System proxies cleared on \(selectedRepairService)"
        ) {
            try await RepairRoutines().cleanProxies(service: selectedRepairService)
        }
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

    // MARK: - Background Tasks & Sensor Streams

    public func startBackgroundTasks() {
        pasteboardWatcher.startMonitoring(interval: 1.5)

        let sensor = injectedNetworkSensor ?? NetworkSensor()
        activeNetworkSensor = sensor
        let ruleEngine = VPNRuleEngine(
            policy: VPNRulePolicy(
                autoConnectEnabled: isVPNAutomationEnabled,
                targetProfileName: activeVPNProfile
            ),
            vpnController: vpnController
        )
        vpnRuleEngine = ruleEngine

        sensor.start()
        ruleEngine.startObserving(sensor: sensor, activeProfile: loadedProfileInfo)

        sensorStreamTask = Task { [weak self] in
            guard let self else { return }
            for await state in sensor.makeEnvironmentStream() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.updateEnvironment(state)
                }
            }
        }

        vpnRuleTask = Task { [weak self] in
            guard let self else { return }
            for await event in ruleEngine.makeEventStream() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.appendRepairLog("VPN automation: \(event.description)")
                }
                await self.refreshVPNState()
            }
        }

        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshHardwareInterfaces()
            await self.refreshServiceOrder()
            await self.refreshVPNState()
            await self.refreshPinnedRoutes()
            await self.refreshPrivateRelayStatus()
            await self.refreshAIModels()
        }

        // 1. Hardware interface byte deltas & proxy live stats (1s cadence)
        throughputTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { break }

                let currentIface = await MainActor.run {
                    self.primaryInterface.isEmpty ? nil : self.primaryInterface
                }
                let counters = DarwinSocketHelper.getInterfaceBytes(for: currentIface)

                await MainActor.run {
                    let now = Date()
                    let dt = max(0.2, now.timeIntervalSince(self.lastInterfaceSampleTime))
                    self.lastInterfaceSampleTime = now

                    var instDown: Double = 0
                    var instUp: Double = 0

                    if self.lastTrackedInterface != currentIface {
                        self.lastTrackedInterface = currentIface
                        self.lastInterfaceIn = counters.inputBytes
                        self.lastInterfaceOut = counters.outputBytes
                    } else if self.lastInterfaceIn > 0 {
                        let deltaIn: UInt64
                        if counters.inputBytes >= self.lastInterfaceIn {
                            deltaIn = counters.inputBytes - self.lastInterfaceIn
                        } else if self.lastInterfaceIn <= UInt64(UInt32.max) {
                            deltaIn = (UInt64(UInt32.max) - self.lastInterfaceIn + 1) + counters.inputBytes
                        } else {
                            deltaIn = 0
                        }

                        let deltaOut: UInt64
                        if counters.outputBytes >= self.lastInterfaceOut {
                            deltaOut = counters.outputBytes - self.lastInterfaceOut
                        } else if self.lastInterfaceOut <= UInt64(UInt32.max) {
                            deltaOut = (UInt64(UInt32.max) - self.lastInterfaceOut + 1) + counters.outputBytes
                        } else {
                            deltaOut = 0
                        }

                        instDown = (deltaIn < 10_000_000_000) ? (Double(deltaIn) / dt) : 0
                        instUp = (deltaOut < 10_000_000_000) ? (Double(deltaOut) / dt) : 0
                    }

                    self.lastInterfaceIn = counters.inputBytes
                    self.lastInterfaceOut = counters.outputBytes

                    self.updateSpeeds(download: instDown, upload: instUp)

                    if self.isProxyActive {
                        self.refreshProxyMetrics()
                    }
                }
            }
        }

        // 2. Concurrent RTT probes (2s cadence) & Hotspot client refresh (4s cadence)
        rttTimerTask = Task { [weak self] in
            var tickCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { break }
                tickCount += 1

                let results = await self.probeEndpointsConcurrently()
                await MainActor.run {
                    for (endpoint, result) in results {
                        self.endpointRTTs[endpoint] = result
                    }
                }

                if tickCount % 2 == 0 {
                    await self.refreshHotspotClients()
                    await self.refreshHardwareInterfaces()
                }
            }
        }

        // 3. Clipboard URL watcher stream
        clipboardStreamTask = Task { [weak self] in
            guard let self else { return }
            for await url in self.pasteboardWatcher.detectedURLs {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.detectedClipboardURL = url
                    self.appendRepairLog("Clipboard detected download URL: \(url.absoluteString)")
                }
            }
        }

        // 4. Download task updates stream
        downloadStreamTask = Task { [weak self] in
            guard let self else { return }
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
        sensorStreamTask?.cancel()
        sensorStreamTask = nil
        vpnRuleTask?.cancel()
        vpnRuleTask = nil
        bootstrapTask?.cancel()
        bootstrapTask = nil
        pasteboardWatcher.stopMonitoring()
        vpnRuleEngine?.stopObserving()
        activeNetworkSensor?.stop()
    }
}
