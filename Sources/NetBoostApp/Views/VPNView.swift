import AppKit
import NetBoostCore
import SwiftUI
import UniformTypeIdentifiers

public struct VPNView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isRefreshingVPN = false
    @State private var isRefreshingServices = false
    @State private var isReorderingServices = false
    @State private var isTogglingVPN = false

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                headerRow

                if let error = appState.vpnError {
                    errorBanner(error)
                }

                profileAndConnectionCard
                routeConflictCard
                servicePriorityCard
            }
            .padding(20)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            PageHeader(
                title: "VPN & Split Routing",
                subtitle: "OpenVPN profiles, route conflict inspection, and interface priority"
            )
            Spacer()
            StatusPill(
                text: statusLabel(appState.vpnStatus),
                color: statusColor(appState.vpnStatus),
                showPulse: appState.vpnStatus == .connected || appState.vpnStatus == .connecting
            )
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(GlassTheme.redAlert)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(GlassTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                appState.vpnError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(GlassTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss error")
        }
        .padding(12)
        .glassCard(cornerRadius: 10, strokeColor: GlassTheme.redAlert.opacity(0.45))
    }

    // MARK: - Profile & Connection Card

    private var profileAndConnectionCard: some View {
        let isConnected = appState.vpnStatus == .connected
        let isTransitioning = appState.vpnStatus == .connecting || appState.vpnStatus == .disconnecting

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                SectionLabel("VPN Connection")
                Spacer()

                Button {
                    Task {
                        isRefreshingVPN = true
                        await appState.refreshVPNState()
                        isRefreshingVPN = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isRefreshingVPN {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh")
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))
                .disabled(isRefreshingVPN)

                Button {
                    presentOVPNImporter()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import .ovpn...")
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))

                Button {
                    Task {
                        await toggleVPNConnection()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isTogglingVPN || isTransitioning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isConnected ? "stop.fill" : "play.fill")
                        }
                        Text(isConnected ? "Disconnect" : "Connect")
                    }
                }
                .buttonStyle(
                    GlowingButtonStyle(
                        accentColor: isConnected ? GlassTheme.redAlert : GlassTheme.emeraldGreen,
                        isProminent: true
                    )
                )
                .disabled(isTogglingVPN || isTransitioning)
            }

            HStack(spacing: 12) {
                Text("Profile")
                    .font(.system(size: 12.5))
                    .foregroundColor(GlassTheme.textSecondary)
                    .frame(width: 60, alignment: .leading)

                Picker("Profile", selection: $appState.activeVPNProfile) {
                    ForEach(availableProfileNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180, maxWidth: 280)

                if let matched = appState.installedProfiles.first(where: { $0.name == appState.activeVPNProfile }) {
                    if matched.isDefault {
                        StatusPill(text: "Default", color: GlassTheme.cyanSapphire, showPulse: false)
                    }
                    Text(matched.serviceType)
                        .font(.system(size: 11.5))
                        .foregroundColor(GlassTheme.textTertiary)
                }

                Spacer()
            }

            if let info = appState.loadedProfileInfo {
                loadedProfileMetadataRow(info)
            }

            Rectangle()
                .fill(GlassTheme.separator)
                .frame(height: 1)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-switch VPN by network")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(GlassTheme.textPrimary)
                    Text("Connects on cellular or external Wi-Fi and disengages on wired LAN.")
                        .font(.system(size: 11.5))
                        .foregroundColor(GlassTheme.textSecondary)
                }
                Spacer()
                Toggle("Auto-switch VPN by network", isOn: $appState.isVPNAutomationEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        .padding(16)
        .glassCard(
            cornerRadius: 12,
            strokeColor: isConnected ? GlassTheme.emeraldGreen.opacity(0.35) : GlassTheme.controlBorder
        )
    }

    private func loadedProfileMetadataRow(_ info: VPNProfileInfo) -> some View {
        HStack(spacing: 16) {
            metadataItem(label: "Server", value: "\(info.serverAddress):\(info.port)")
            metadataItem(label: "Protocol", value: info.proto.uppercased())
            if let cipher = info.cipher, !cipher.isEmpty {
                metadataItem(label: "Cipher", value: cipher)
            }
            Spacer()
            StatusPill(
                text: info.isCampusSplit ? "Split Tunnel" : "Full Tunnel",
                color: info.isCampusSplit ? GlassTheme.emeraldGreen : GlassTheme.amberWarning,
                showPulse: false
            )
        }
        .padding(10)
        .background(GlassTheme.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
        )
    }

    private func metadataItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(GlassTheme.textTertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(GlassTheme.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - Route Conflict Inspector

    private var routeConflictCard: some View {
        let hasConflicts = !appState.routeConflicts.isEmpty || (appState.conflictReport?.hasConflicts ?? false)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionLabel("Route Conflict Inspector")
                Spacer()

                if hasConflicts {
                    StatusPill(
                        text: "\(appState.routeConflicts.count) Conflict\(appState.routeConflicts.count == 1 ? "" : "s")",
                        color: GlassTheme.amberWarning,
                        showPulse: false
                    )
                } else if appState.conflictReport != nil {
                    StatusPill(text: "Clear", color: GlassTheme.emeraldGreen, showPulse: false)
                }

                Button {
                    appState.checkRouteConflicts()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                        Text("Check Conflicts")
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.amberWarning))
            }

            if hasConflicts {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(appState.routeConflicts.enumerated()), id: \.offset) { _, conflict in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(GlassTheme.amberWarning)
                                .padding(.top, 2)
                            Text(conflict)
                                .font(.system(size: 12))
                                .foregroundColor(GlassTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let advice = appState.conflictReport?.remediationAdvice, !advice.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: 12))
                                .foregroundColor(GlassTheme.cyanSapphire)
                                .padding(.top, 2)
                            Text(advice)
                                .font(.system(size: 11.5))
                                .foregroundColor(GlassTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GlassTheme.amberWarning.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(GlassTheme.amberWarning.opacity(0.32), lineWidth: 0.75)
                )
            } else if appState.conflictReport != nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(GlassTheme.emeraldGreen)
                    Text("No route overlaps detected against active local interfaces.")
                        .font(.system(size: 12))
                        .foregroundColor(GlassTheme.textSecondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GlassTheme.emeraldGreen.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Parsed Routes")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(GlassTheme.textSecondary)
                    Text("(\(appState.parsedRoutes.count))")
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.textTertiary)
                }

                if appState.parsedRoutes.isEmpty {
                    Text("Import an .ovpn profile to inspect pushed routes, or run Check Conflicts to evaluate the active profile.")
                        .font(.system(size: 12))
                        .foregroundColor(GlassTheme.textTertiary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GlassTheme.controlFill)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(appState.parsedRoutes.enumerated()), id: \.offset) { _, route in
                            routeRow(route)
                        }
                    }
                }
            }
        }
        .padding(16)
        .glassCard(
            cornerRadius: 12,
            strokeColor: hasConflicts ? GlassTheme.amberWarning.opacity(0.4) : GlassTheme.controlBorder
        )
    }

    private func routeRow(_ route: VPNRouteEntry) -> some View {
        let isCampusOverlap = route.destinationSubnet.hasPrefix("10.1.")
        return HStack(spacing: 12) {
            Circle()
                .fill(isCampusOverlap ? GlassTheme.amberWarning : GlassTheme.cyanSapphire)
                .frame(width: 6, height: 6)

            Text(route.destinationSubnet)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(GlassTheme.textPrimary)

            Text(route.mask)
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(GlassTheme.textSecondary)

            Spacer()

            if let gateway = route.gateway, !gateway.isEmpty {
                Text("via \(gateway)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(GlassTheme.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Network Service Priority Order

    private var servicePriorityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionLabel("Network Service Priority Order")
                Spacer()
                Button {
                    Task {
                        isRefreshingServices = true
                        await appState.refreshServiceOrder()
                        isRefreshingServices = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isRefreshingServices {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh")
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))
                .disabled(isRefreshingServices || isReorderingServices)
            }

            if appState.networkServiceOrder.isEmpty {
                Text("No network services detected.")
                    .font(.system(size: 12))
                    .foregroundColor(GlassTheme.textTertiary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(appState.networkServiceOrder.enumerated()), id: \.offset) { index, service in
                        serviceOrderRow(index: index, service: service)
                    }
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    private func serviceOrderRow(index: Int, service: String) -> some View {
        let isPrimary = index == 0
        let isLast = index == appState.networkServiceOrder.count - 1

        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(isPrimary ? GlassTheme.cyanSapphire : GlassTheme.textTertiary)
                .frame(width: 24, alignment: .center)

            Text(service)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(GlassTheme.textPrimary)
                .lineLimit(1)

            Spacer()

            StatusPill(
                text: isPrimary ? "Primary" : "Fallback",
                color: isPrimary ? GlassTheme.emeraldGreen : GlassTheme.textTertiary,
                showPulse: false
            )

            HStack(spacing: 4) {
                Button {
                    Task { await moveService(at: index, offset: -1) }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isPrimary || isReorderingServices)
                .help("Move service up")
                .accessibilityLabel("Move \(service) up")

                Button {
                    Task { await moveService(at: index, offset: 1) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLast || isReorderingServices)
                .help("Move service down")
                .accessibilityLabel("Move \(service) down")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(GlassTheme.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
        )
    }

    // MARK: - Helpers & Actions

    private var availableProfileNames: [String] {
        var names = appState.installedProfiles.map(\.name)
        if !appState.activeVPNProfile.isEmpty && !names.contains(appState.activeVPNProfile) {
            names.append(appState.activeVPNProfile)
        }
        if names.isEmpty {
            names = ["macos.ovpn"]
        }
        return names
    }

    private func presentOVPNImporter() {
        let panel = NSOpenPanel()
        panel.title = "Import OpenVPN Profile"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ovpnType = UTType(filenameExtension: "ovpn") {
            panel.allowedContentTypes = [ovpnType]
        }
        if panel.runModal() == .OK, let url = panel.url {
            appState.importOVPNProfile(url: url)
        }
    }

    private func toggleVPNConnection() async {
        isTogglingVPN = true
        defer { isTogglingVPN = false }
        do {
            try await appState.toggleVPN()
        } catch {
            appState.vpnError = error.localizedDescription
        }
    }

    private func moveService(at index: Int, offset: Int) async {
        isReorderingServices = true
        defer { isReorderingServices = false }
        do {
            try await appState.moveService(at: index, offset: offset)
            appState.vpnError = nil
        } catch {
            appState.vpnError = "Could not reorder services: \(error.localizedDescription)"
        }
    }

    private func statusLabel(_ status: VPNStatus) -> String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .disconnected: return "Disconnected"
        case .error: return "Error"
        }
    }

    private func statusColor(_ status: VPNStatus) -> Color {
        switch status {
        case .connected: return GlassTheme.emeraldGreen
        case .connecting, .disconnecting: return GlassTheme.amberWarning
        case .disconnected: return GlassTheme.textTertiary
        case .error: return GlassTheme.redAlert
        }
    }
}
