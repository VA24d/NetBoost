import SwiftUI
import NetBoostCore

public struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isRefreshingInterfaces = false

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                headerRow
                networkFlowSection
                quickControlsSection
                hardwareInterfacesSection
            }
            .padding(20)
        }
        .task {
            if appState.hardwareInterfaces.isEmpty {
                await appState.refreshHardwareInterfaces()
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            PageHeader(
                title: "Dashboard",
                subtitle: "Live hardware interfaces, active routing flow, and service controls"
            )
            Spacer(minLength: 12)
            StatusPill(
                text: appState.activeStatePill,
                color: environmentColor(appState.activeEnvironment),
                showPulse: appState.activeEnvironment.isConnected
            )
        }
    }

    // MARK: - Network Flow Overview

    private var networkFlowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Network flow overview")
                Spacer()
                Text(throughputSummary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textSecondary)
            }

            HStack(spacing: 6) {
                flowStageCard(
                    icon: uplinkIcon,
                    title: "Active uplink",
                    status: appState.activeEnvironment.isConnected
                        ? (appState.primaryInterface.isEmpty ? "Connected" : appState.primaryInterface)
                        : "Offline",
                    detail: appState.primaryInterfaceIP,
                    accentColor: environmentColor(appState.activeEnvironment),
                    isActive: appState.activeEnvironment.isConnected,
                    destination: .doctor
                )

                flowConnector(active: appState.activeEnvironment.isConnected)

                flowStageCard(
                    icon: "lock.shield",
                    title: "VPN tunnel",
                    status: vpnStatusLabel(appState.vpnStatus),
                    detail: appState.activeVPNProfile,
                    accentColor: vpnStatusColor(appState.vpnStatus),
                    isActive: appState.vpnStatus == .connected,
                    destination: .vpn
                )

                flowConnector(active: appState.isProxyActive)

                flowStageCard(
                    icon: "arrow.triangle.branch",
                    title: "Proxy dispatcher",
                    status: appState.isProxyActive ? "Listening" : "Off",
                    detail: "\(appState.activeConnections.count) active · \(appState.proxyPorts.count) ports",
                    accentColor: appState.isProxyActive ? GlassTheme.cyanSapphire : GlassTheme.textTertiary,
                    isActive: appState.isProxyActive,
                    destination: .dispatcher
                )

                flowConnector(active: appState.isHotspotActive)

                flowStageCard(
                    icon: "personalhotspot",
                    title: "Hotspot",
                    status: hotspotStageStatus,
                    detail: hotspotStageDetail,
                    accentColor: hotspotStageColor,
                    isActive: appState.isHotspotActive,
                    destination: .hotspot
                )
            }
            .padding(14)
            .glassCard(cornerRadius: 12)
        }
    }

    private func flowStageCard(
        icon: String,
        title: String,
        status: String,
        detail: String,
        accentColor: Color,
        isActive: Bool,
        destination: AppNavigationTab
    ) -> some View {
        Button {
            appState.selectedTab = destination
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(accentColor)
                    Spacer(minLength: 4)
                    Circle()
                        .fill(isActive ? accentColor : GlassTheme.textTertiary.opacity(0.5))
                        .frame(width: 7, height: 7)
                }

                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(GlassTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(status)
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .truncationMode(.tail)

                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GlassTheme.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isActive ? accentColor.opacity(0.4) : GlassTheme.controlBorder,
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func flowConnector(active: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(active ? GlassTheme.cyanSapphire : GlassTheme.textTertiary.opacity(0.6))
    }

    // MARK: - Quick Controls

    private var quickControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Quick controls")

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                quickControlTile(
                    title: "Hotspot",
                    icon: "personalhotspot",
                    statusText: hotspotStageStatus,
                    statusColor: hotspotStageColor,
                    metric: hotspotQuickMetric,
                    detail: hotspotQuickDetail,
                    tab: .hotspot
                )

                quickControlTile(
                    title: "Proxy Dispatcher",
                    icon: "arrow.triangle.branch",
                    statusText: appState.isProxyActive ? "Active" : "Off",
                    statusColor: appState.isProxyActive ? GlassTheme.cyanSapphire : GlassTheme.textTertiary,
                    metric: "\(appState.activeConnections.count) active",
                    detail: "Rx \(SpeedFormatter.formatBytes(appState.proxyTotalBytesRead)) · Tx \(SpeedFormatter.formatBytes(appState.proxyTotalBytesWritten))",
                    tab: .dispatcher
                )

                quickControlTile(
                    title: "VPN",
                    icon: "lock.shield",
                    statusText: vpnStatusLabel(appState.vpnStatus),
                    statusColor: vpnStatusColor(appState.vpnStatus),
                    metric: appState.activeVPNProfile,
                    detail: appState.routeConflicts.isEmpty
                        ? "No route conflicts"
                        : "\(appState.routeConflicts.count) route \(appState.routeConflicts.count == 1 ? "conflict" : "conflicts")",
                    tab: .vpn
                )

                quickControlTile(
                    title: "Network Doctor",
                    icon: "cross.case",
                    statusText: appState.activeIssues.isEmpty ? "Healthy" : "\(appState.activeIssues.count) \(appState.activeIssues.count == 1 ? "issue" : "issues")",
                    statusColor: appState.activeIssues.isEmpty ? GlassTheme.emeraldGreen : GlassTheme.amberWarning,
                    metric: doctorSummaryMetric,
                    detail: captivePortalLabel(appState.captivePortalStatus),
                    tab: .doctor
                )
            }
        }
    }

    private func quickControlTile(
        title: String,
        icon: String,
        statusText: String,
        statusColor: Color,
        metric: String,
        detail: String,
        tab: AppNavigationTab
    ) -> some View {
        Button {
            appState.selectedTab = tab
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(statusColor)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(GlassTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(GlassTheme.textTertiary)
                }

                StatusPill(
                    text: statusText,
                    color: statusColor,
                    showPulse: false
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(metric)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(detail)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 12, strokeColor: statusColor.opacity(0.28))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Active Hardware Interfaces

    private var hardwareInterfacesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionLabel("Active hardware interfaces")
                if !appState.hardwareInterfaces.isEmpty {
                    Text("\(appState.hardwareInterfaces.count)")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(GlassTheme.controlFill)
                        .clipShape(Capsule())
                }
                Spacer()
                Button {
                    Task {
                        isRefreshingInterfaces = true
                        defer { isRefreshingInterfaces = false }
                        await appState.refreshHardwareInterfaces()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isRefreshingInterfaces {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11.5))
                        }
                        Text("Refresh")
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))
                .disabled(isRefreshingInterfaces)
            }

            if appState.hardwareInterfaces.isEmpty {
                primaryInterfaceFallbackCard
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 290), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(sortedInterfaces) { iface in
                        hardwareInterfaceCard(iface)
                    }
                }
            }
        }
    }

    private var effectivePrimaryBSDName: String? {
        if appState.hardwareInterfaces.contains(where: { $0.bsdName == appState.primaryInterface && $0.isUp }) {
            return appState.primaryInterface
        }
        return appState.hardwareInterfaces.first(where: { $0.isPrimary && $0.isUp })?.bsdName
            ?? appState.hardwareInterfaces.first(where: { $0.isPrimary })?.bsdName
    }

    private var sortedInterfaces: [NetworkInterfaceInfo] {
        let primaryBSD = effectivePrimaryBSDName
        return appState.hardwareInterfaces.sorted { lhs, rhs in
            let lhsPrimary = (lhs.bsdName == primaryBSD)
            let rhsPrimary = (rhs.bsdName == primaryBSD)
            if lhsPrimary != rhsPrimary { return lhsPrimary }
            if lhs.isUp != rhs.isUp { return lhs.isUp }
            return lhs.bsdName.localizedStandardCompare(rhs.bsdName) == .orderedAscending
        }
    }

    private func hardwareInterfaceCard(_ iface: NetworkInterfaceInfo) -> some View {
        let isPrimary = (iface.bsdName == effectivePrimaryBSDName)
        let accent: Color = iface.isUp
            ? (isPrimary ? GlassTheme.sapphireBlue : GlassTheme.emeraldGreen)
            : GlassTheme.textTertiary

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: iconForInterface(iface.bsdName))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(accent)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(iface.displayName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(GlassTheme.textPrimary)
                            .lineLimit(1)
                        if iface.displayName != iface.bsdName {
                            Text(iface.bsdName)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundColor(GlassTheme.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(GlassTheme.controlFill)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                }

                Spacer(minLength: 8)

                if isPrimary {
                    Text("Primary")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(GlassTheme.cyanSapphire)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(GlassTheme.cyanSapphire.opacity(0.14))
                        .clipShape(Capsule())
                }

                StatusPill(
                    text: iface.isUp ? "Up" : "Down",
                    color: iface.isUp ? GlassTheme.emeraldGreen : GlassTheme.textTertiary,
                    showPulse: iface.isUp
                )
            }

            Rectangle()
                .fill(GlassTheme.separator.opacity(0.6))
                .frame(height: 1)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .trailing)
                ],
                spacing: 10
            ) {
                interfaceMetricCell(
                    label: "IPv4 address",
                    value: iface.ipv4Address ?? "Unassigned",
                    alignment: .leading
                )

                interfaceMetricCell(
                    label: "Gateway",
                    value: iface.gateway ?? "None",
                    alignment: .trailing
                )

                interfaceMetricCell(
                    label: "MTU",
                    value: "\(iface.mtu)",
                    valueColor: iface.mtu == 1280 ? GlassTheme.amberWarning : GlassTheme.textPrimary,
                    alignment: .leading
                )

                interfaceMetricCell(
                    label: "MAC address",
                    value: iface.macAddress ?? "Unavailable",
                    valueColor: GlassTheme.textSecondary,
                    alignment: .trailing
                )
            }
        }
        .padding(14)
        .glassCard(
            cornerRadius: 12,
            strokeColor: iface.isUp ? accent.opacity(0.35) : Color.white.opacity(0.08)
        )
    }

    private var primaryInterfaceFallbackCard: some View {
        let isOnline = appState.activeEnvironment.isConnected
        let ifaceName = appState.primaryInterface.isEmpty ? "Unknown" : appState.primaryInterface
        let accent = environmentColor(appState.activeEnvironment)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: iconForInterface(ifaceName))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ifaceName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(GlassTheme.textPrimary)
                    Text("Primary uplink telemetry")
                        .font(.system(size: 11))
                        .foregroundColor(GlassTheme.textSecondary)
                }

                Spacer()

                StatusPill(
                    text: isOnline ? "Up" : "Down",
                    color: isOnline ? GlassTheme.emeraldGreen : GlassTheme.textTertiary,
                    showPulse: isOnline
                )
            }

            Rectangle()
                .fill(GlassTheme.separator.opacity(0.6))
                .frame(height: 1)

            HStack(spacing: 24) {
                interfaceMetricCell(
                    label: "Interface",
                    value: ifaceName,
                    alignment: .leading
                )
                interfaceMetricCell(
                    label: "IPv4 address",
                    value: appState.primaryInterfaceIP,
                    alignment: .leading
                )
                if appState.activeEnvironment.mtu > 0 {
                    interfaceMetricCell(
                        label: "MTU",
                        value: "\(appState.activeEnvironment.mtu)",
                        alignment: .leading
                    )
                }
                Spacer()
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 12, strokeColor: accent.opacity(0.35))
    }

    private func interfaceMetricCell(
        label: String,
        value: String,
        valueColor: Color = GlassTheme.textPrimary,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(GlassTheme.textTertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }

    // MARK: - Formatting Helpers

    private var throughputSummary: String {
        let down = SpeedFormatter.formatSpeed(appState.smoothedDownloadBps)
        let up = SpeedFormatter.formatSpeed(appState.smoothedUploadBps)
        return "Down \(down) · Up \(up)"
    }

    private var uplinkIcon: String {
        if !appState.activeEnvironment.isConnected { return "wifi.slash" }
        return iconForInterface(appState.primaryInterface)
    }

    private var hotspotStageStatus: String {
        if appState.isUpstreamProtectedBy8021X && !appState.isHotspotActive {
            return "Blocked (802.1X)"
        }
        if !appState.canEnableHotspot && !appState.isHotspotActive {
            return "Unavailable"
        }
        guard appState.isHotspotActive else { return "Off" }
        if appState.isRadioBroadcasting {
            return "Broadcasting"
        }
        return appState.isUpstreamProtectedBy8021X ? "Blocked (802.1X)" : "Waiting for macOS"
    }

    private var hotspotStageColor: Color {
        if appState.isUpstreamProtectedBy8021X {
            return GlassTheme.amberWarning
        }
        guard appState.isHotspotActive else { return GlassTheme.textTertiary }
        return appState.isRadioBroadcasting ? GlassTheme.emeraldGreen : GlassTheme.amberWarning
    }

    private var hotspotStageDetail: String {
        if appState.isUpstreamProtectedBy8021X {
            return "\(appState.upstreamInterface) · 802.1X"
        }
        return "\(appState.connectedClients.count) \(appState.connectedClients.count == 1 ? "client" : "clients")"
    }

    private var hotspotQuickMetric: String {
        if appState.isUpstreamProtectedBy8021X {
            return "eapolclient active"
        }
        if !appState.canEnableHotspot && !appState.isHotspotActive {
            return "No ready uplink"
        }
        return "\(appState.connectedClients.count) \(appState.connectedClients.count == 1 ? "client" : "clients")"
    }

    private var hotspotQuickDetail: String {
        if appState.isUpstreamProtectedBy8021X {
            return "Use Proxy Dispatcher or non-802.1X uplink"
        }
        if !appState.canEnableHotspot && !appState.isHotspotActive {
            return "Requires non-802.1X wired Ethernet"
        }
        return "\(appState.upstreamInterface) to \(appState.downstreamInterface)"
    }

    private var doctorSummaryMetric: String {
        let probes = appState.endpointRTTs.values
        guard !probes.isEmpty else { return "Ready to scan" }
        let reachable = probes.filter(\.isReachable)
        if let fastest = reachable.min(by: { $0.latencyMs < $1.latencyMs }) {
            return String(format: "%.1f ms · %d/%d up", fastest.latencyMs, reachable.count, AppState.targetEndpoints.count)
        }
        return "0/\(AppState.targetEndpoints.count) reachable"
    }

    private func iconForInterface(_ bsdName: String) -> String {
        if bsdName == "en0" { return "wifi" }
        if bsdName.hasPrefix("utun") { return "lock.shield" }
        if bsdName.hasPrefix("bridge") || bsdName.hasPrefix("ap") { return "personalhotspot" }
        if bsdName.hasPrefix("lo") { return "arrow.triangle.2.circlepath" }
        return "cable.connector"
    }

    private func environmentColor(_ env: NetworkEnvironmentState) -> Color {
        switch env {
        case .campusLAN: return GlassTheme.sapphireBlue
        case .cellularHotspot: return GlassTheme.amberWarning
        case .externalWiFi: return GlassTheme.cyanSapphire
        case .disconnected: return GlassTheme.redAlert
        }
    }

    private func vpnStatusLabel(_ status: VPNStatus) -> String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .disconnected: return "Off"
        case .error: return "Error"
        }
    }

    private func vpnStatusColor(_ status: VPNStatus) -> Color {
        switch status {
        case .connected: return GlassTheme.emeraldGreen
        case .connecting, .disconnecting: return GlassTheme.amberWarning
        case .disconnected: return GlassTheme.textTertiary
        case .error: return GlassTheme.redAlert
        }
    }

    private func captivePortalLabel(_ status: CaptivePortalStatus) -> String {
        switch status {
        case .notDetected: return "No captive portal"
        case .detected: return "Captive portal detected"
        case .redirecting: return "Login redirect active"
        case .authenticated: return "Portal authenticated"
        case .unknown: return "Portal check pending"
        }
    }
}
