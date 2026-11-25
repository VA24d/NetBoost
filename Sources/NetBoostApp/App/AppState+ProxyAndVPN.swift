import AppKit
import Foundation
import NetBoostCore

@MainActor
extension AppState {

    // MARK: - Proxy Dispatcher & Route Pinning Actions

    public func toggleProxy() async throws {
        if isProxyActive {
            try await proxyDispatcher.stop()
            isProxyActive = false
            activeConnections = []
            proxyTotalBytesRead = 0
            proxyTotalBytesWritten = 0
            appendRepairLog("Proxy Dispatcher stopped.")
        } else {
            try await proxyDispatcher.start(ports: proxyPorts)
            isProxyActive = true
            refreshProxyMetrics()
            appendRepairLog("Proxy Dispatcher started on ports: \(proxyPorts.keys.sorted())")
        }
        proxyError = nil
    }

    public func refreshProxyMetrics() {
        activeConnections = proxyDispatcher.activeConnections
        if let concrete = proxyDispatcher as? InterfaceProxyDispatcher {
            proxyTotalBytesRead = concrete.totalBytesRead
            proxyTotalBytesWritten = concrete.totalBytesWritten
        }
    }

    public func generateShellSnippet(port: Int) -> String {
        let snippet = proxyDispatcher.generateShellSnippet(port: port)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        copiedSnippetMessage = "Copied snippet for port \(port)"
        return snippet
    }

    public func refreshPinnedRoutes() async {
        if let routes = try? await routePinningEngine.currentPinnedRoutes() {
            pinnedRoutes = routes
        }
    }

    public func pinSubnet(_ subnet: String, gateway: String? = nil, interface: String? = nil) async {
        let resolvedGateway = gateway ?? hardwareInterfaces.first(where: { $0.bsdName == (interface ?? upstreamInterface) })?.gateway ?? RoutePinningEngine.defaultGateway
        let resolvedIface = interface ?? upstreamInterface
        let result = await routePinningEngine.pinSubnet(subnet: subnet, gateway: resolvedGateway, interface: resolvedIface)
        await refreshAuthorizationStatus()
        routePinResultMessage = result.message
        appendRepairLog("Route pin \(subnet) via \(resolvedIface): \(result.message)")
        await refreshPinnedRoutes()
    }

    public func unpinSubnet(_ subnet: String, gateway: String? = nil) async {
        let resolvedGateway = gateway ?? RoutePinningEngine.defaultGateway
        let result = await routePinningEngine.unpinSubnet(subnet: subnet, gateway: resolvedGateway)
        await refreshAuthorizationStatus()
        routePinResultMessage = result.message
        appendRepairLog("Route unpin \(subnet): \(result.message)")
        await refreshPinnedRoutes()
    }

    public func pinCampusDefaultSubnets() async {
        let gw = hardwareInterfaces.first(where: { $0.bsdName == upstreamInterface })?.gateway ?? RoutePinningEngine.defaultGateway
        await pinSubnet("10.8.0.0/16", gateway: gw, interface: upstreamInterface)
        await pinSubnet("10.4.0.0/16", gateway: gw, interface: upstreamInterface)
    }

    public func launchCLITask(command: String, port: Int) async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunningCLITask else { return }
        guard (1...65535).contains(port) else {
            cliTaskOutput = "Invalid proxy port: \(port). Expected 1–65535."
            return
        }

        isRunningCLITask = true
        defer { isRunningCLITask = false }

        let socksURL = "socks5://127.0.0.1:\(port)"
        let httpURL = "http://127.0.0.1:\(port)"
        var env = ProcessInfo.processInfo.environment
        env["ALL_PROXY"] = socksURL
        env["all_proxy"] = socksURL
        env["HTTP_PROXY"] = httpURL
        env["http_proxy"] = httpURL
        env["HTTPS_PROXY"] = httpURL
        env["https_proxy"] = httpURL

        do {
            let output = try await ShellCommand.run("/bin/zsh", arguments: ["-c", trimmed], environment: env, timeout: 20.0)
            let combined = [output.stdout, output.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            cliTaskOutput = combined.isEmpty ? "Completed with exit code \(output.exitCode)." : combined
        } catch {
            cliTaskOutput = "Command failed: \(error.localizedDescription)"
        }
    }

    // MARK: - VPN & Service Priority Actions

    public func toggleVPN() async throws {
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

    public func refreshVPNState() async {
        if let concrete = vpnController as? PassepartoutController,
           let profiles = try? await concrete.listProfiles() {
            installedProfiles = profiles
            if let connected = profiles.first(where: { $0.status == .connected }) {
                activeVPNProfile = connected.name
                vpnStatus = .connected
                return
            }
            if !profiles.contains(where: { $0.name == activeVPNProfile }), let first = profiles.first {
                activeVPNProfile = first.name
            }
        }
        vpnStatus = await vpnController.checkStatus(profileName: activeVPNProfile)
    }

    public func importOVPNProfile(url: URL) {
        do {
            let info = try vpnController.parseProfile(url: url)
            loadedProfileInfo = info
            parsedRoutes = info.routes
            activeVPNProfile = url.lastPathComponent
            checkRouteConflicts()
            vpnError = nil
            appendRepairLog("Loaded OpenVPN profile: \(info.name) (\(info.routes.count) routes)")
        } catch {
            vpnError = "Could not parse profile: \(error.localizedDescription)"
            appendRepairLog("OpenVPN parse failed: \(error.localizedDescription)")
        }
    }

    public func checkRouteConflicts() {
        let profile = loadedProfileInfo ?? VPNProfileInfo(
            name: activeVPNProfile,
            serverAddress: "vpn.campus.net",
            routes: parsedRoutes.isEmpty ? [
                VPNRouteEntry(destinationSubnet: "10.1.0.0", mask: "255.255.0.0"),
                VPNRouteEntry(destinationSubnet: "0.0.0.0", mask: "0.0.0.0")
            ] : parsedRoutes
        )

        if !hardwareInterfaces.isEmpty {
            let report = RouteConflictDetector.detectConflicts(profile: profile, interfaces: hardwareInterfaces)
            conflictReport = report
            routeConflicts = report.conflictDescriptions
        } else {
            conflictReport = nil
            routeConflicts = vpnController.detectConflicts(profile: profile, currentLAN: "10.1.36.0/22")
        }
    }

    public func refreshServiceOrder() async {
        if let entries = try? await serviceOrderManager.getServiceOrder(), !entries.isEmpty {
            serviceEntries = entries
            networkServiceOrder = entries.map(\.name)
            let physicalNames = entries
                .filter { !$0.device.isEmpty && !$0.name.hasPrefix("*") }
                .map(\.name)
            let names = physicalNames.isEmpty ? entries.map(\.name) : physicalNames
            availableServices = names
            if !names.contains(selectedRepairService), let first = names.first {
                selectedRepairService = first
            }
        }
    }

    public func moveService(at index: Int, offset: Int) async throws {
        let target = index + offset
        guard networkServiceOrder.indices.contains(index),
              networkServiceOrder.indices.contains(target) else { return }
        var updated = networkServiceOrder
        updated.swapAt(index, target)
        try await reorderServices(ordered: updated)
    }

    public func reorderServices(ordered: [String]) async throws {
        try await campusDoctor.reorderServices(ordered: ordered)
        await refreshAuthorizationStatus()
        networkServiceOrder = ordered
        appendRepairLog("Network service order updated: \(ordered.joined(separator: " -> "))")
    }
}
