import AppKit
import SwiftUI
import NetBoostCore

public struct HotspotView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showPassword = false
    @State private var copiedConfirmation = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var isToggling = false
    @State private var isRefreshingClients = false

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                headerRow
                noticeBanners
                sharingControlCard
                configurationCard
                connectedClientsCard
            }
            .padding(20)
        }
        .task {
            await appState.refreshHotspotClients()
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            PageHeader(
                title: "Hotspot",
                subtitle: "Share wired Ethernet (\(appState.upstreamInterface)) over Wi-Fi (\(appState.downstreamInterface)) using NAT and DHCP"
            )
            Spacer(minLength: 12)
            StatusPill(
                text: hotspotStatusText,
                color: hotspotStatusColor,
                showPulse: appState.isHotspotActive
            )
        }
    }

    // MARK: - Notice Banners

    @ViewBuilder
    private var noticeBanners: some View {
        if let err = appState.hotspotError, !err.isEmpty {
            bannerView(
                icon: "exclamationmark.triangle.fill",
                tint: GlassTheme.redAlert,
                title: "Hotspot error",
                message: err,
                actionTitle: nil,
                action: nil
            )
        }

        if appState.isWiFiConnectedToExternalNetwork {
            bannerView(
                icon: "wifi.exclamationmark",
                tint: GlassTheme.amberWarning,
                title: "Wi-Fi (\(appState.downstreamInterface)) is joined to an external network",
                message: "Disconnect from your current Wi-Fi network in the menu bar before broadcasting '\(appState.hotspotSSID)'. Your Mac will continue using \(appState.upstreamInterface) for internet access.",
                actionTitle: "Sharing Settings",
                action: { appState.openSystemSharingSettings() }
            )
        }

        if !appState.canEnableHotspot {
            bannerView(
                icon: "cable.connector.slash",
                tint: GlassTheme.amberWarning,
                title: "Wired Ethernet uplink required",
                message: "Connect and authenticate wired Ethernet (en10) to enable Wi-Fi sharing.",
                actionTitle: "Sharing Settings",
                action: { appState.openSystemSharingSettings() }
            )
        }
    }

    private func bannerView(
        icon: String,
        tint: Color,
        title: String,
        message: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(GlassTheme.textPrimary)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundColor(GlassTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(GlowingButtonStyle(accentColor: tint))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 0.75)
        )
    }

    // MARK: - Master Sharing Card

    private var sharingControlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share wired Ethernet over Wi-Fi")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(GlassTheme.textPrimary)
                    Text("Routes packets from \(appState.upstreamInterface) (upstream) to \(appState.downstreamInterface) (access point)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.textSecondary)
                }

                Spacer(minLength: 12)

                Toggle("Share wired Ethernet over Wi-Fi", isOn: Binding(
                    get: { appState.isHotspotActive },
                    set: { _ in
                        Task {
                            isToggling = true
                            defer { isToggling = false }
                            do {
                                try await appState.toggleHotspot()
                            } catch {
                                appState.hotspotError = error.localizedDescription
                            }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!appState.canEnableHotspot || isToggling)
                .help(appState.canEnableHotspot ? "Enable or stop NAT sharing" : "Requires active wired Ethernet (en10)")
            }

            if appState.isHotspotActive {
                if appState.isRadioBroadcasting {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(GlassTheme.emeraldGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wi-Fi hotspot is broadcasting")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(GlassTheme.textPrimary)
                            Text("Network '\(appState.hotspotSSID)' is active on \(appState.downstreamInterface).")
                                .font(.system(size: 11.5))
                                .foregroundColor(GlassTheme.textSecondary)
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GlassTheme.emeraldGreen.opacity(0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(GlassTheme.emeraldGreen.opacity(0.32), lineWidth: 0.75)
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(GlassTheme.amberWarning)
                            Text("Enable Internet Sharing in System Settings")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(GlassTheme.textPrimary)
                        }

                        Text("Kernel NAT and packet filter rules are ready. Turn on macOS Internet Sharing to activate the Wi-Fi access point:")
                            .font(.system(size: 11.5))
                            .foregroundColor(GlassTheme.textSecondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("1. Open System Settings -> General -> Sharing.")
                            Text("2. Set 'Share your connection from' to \(appState.upstreamInterface).")
                            Text("3. Select Wi-Fi (\(appState.downstreamInterface)) under 'To devices using'.")
                            Text("4. Switch Internet Sharing on.")
                        }
                        .font(.system(size: 11.5))
                        .foregroundColor(GlassTheme.textPrimary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.24))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button {
                            appState.openSystemSharingSettings()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.forward.app")
                                Text("Open System Sharing Settings")
                            }
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire, isProminent: true))
                    }
                    .padding(12)
                    .background(GlassTheme.amberWarning.opacity(0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(GlassTheme.amberWarning.opacity(0.32), lineWidth: 0.75)
                    )
                }
            }

            HStack {
                Button {
                    appState.openSystemSharingSettings()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11.5))
                        Text("Open System Sharing Settings")
                    }
                }
                .buttonStyle(GlowingButtonStyle())

                Spacer()

                Text("Enterprise 802.1X Wi-Fi cannot act as an access point simultaneously; wired \(appState.upstreamInterface) supplies the uplink.")
                    .font(.system(size: 11))
                    .foregroundColor(GlassTheme.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(16)
        .glassCard(
            cornerRadius: 12,
            strokeColor: appState.isHotspotActive ? hotspotStatusColor.opacity(0.45) : Color.white.opacity(0.10)
        )
    }

    // MARK: - Configuration Section

    private var configurationCard: some View {
        let isSSIDInvalid = appState.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.hotspotSSID.utf8.count > 32
        let isPasswordInvalid = appState.hotspotPassword.utf8.count < 8 || appState.hotspotPassword.utf8.count > 63

        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Configuration")

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Network name")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(GlassTheme.textSecondary)

                    TextField("NetBoost", text: $appState.hotspotSSID)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(GlassTheme.controlFill)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    isSSIDInvalid ? GlassTheme.amberWarning.opacity(0.6) : GlassTheme.controlBorder,
                                    lineWidth: 0.75
                                )
                        )
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Password")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(GlassTheme.textSecondary)

                        Spacer()

                        if copiedConfirmation {
                            Text("Copied")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(GlassTheme.emeraldGreen)
                        } else if isPasswordInvalid {
                            Text("8-63 bytes required")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(GlassTheme.amberWarning)
                        }
                    }

                    HStack(spacing: 8) {
                        Group {
                            if showPassword {
                                TextField("Passphrase", text: $appState.hotspotPassword)
                            } else {
                                SecureField("Passphrase", text: $appState.hotspotPassword)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 12.5))
                                .foregroundColor(showPassword ? GlassTheme.cyanSapphire : GlassTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(showPassword ? "Hide password" : "Show password")
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")

                        Button {
                            copyPassword()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundColor(GlassTheme.cyanSapphire)
                        }
                        .buttonStyle(.plain)
                        .help("Copy password")
                        .accessibilityLabel("Copy password")

                        Button {
                            generatePassphrase()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                                .foregroundColor(GlassTheme.emeraldGreen)
                        }
                        .buttonStyle(.plain)
                        .help("Generate random passphrase")
                        .accessibilityLabel("Generate random passphrase")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isPasswordInvalid
                                    ? GlassTheme.amberWarning.opacity(0.6)
                                    : GlassTheme.controlBorder,
                                lineWidth: 0.75
                            )
                    )
                }
                .frame(maxWidth: .infinity)
            }

            if let validationError = appState.hotspotPasswordValidationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                    Text(validationError)
                        .font(.system(size: 11.5))
                }
                .foregroundColor(GlassTheme.amberWarning)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Security")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(GlassTheme.textSecondary)

                Picker("Security", selection: $appState.hotspotSecurityType) {
                    ForEach(HotspotSecurityType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Rectangle()
                .fill(GlassTheme.separator.opacity(0.6))
                .frame(height: 1)

            // Technical summary strip
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 205), spacing: 12)],
                spacing: 10
            ) {
                summaryItem(label: "Subnet", value: appState.hotspotConfig.subnet)
                summaryItem(label: "Gateway", value: appState.hotspotConfig.gateway, valueColor: GlassTheme.emeraldGreen)
                summaryItem(
                    label: "DHCP pool",
                    value: "\(appState.hotspotConfig.dhcpRangeStart) – \(appState.hotspotConfig.dhcpRangeEnd)",
                    valueColor: GlassTheme.cyanSapphire
                )
                summaryItem(label: "PF anchor", value: "netboost")
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    private func summaryItem(
        label: String,
        value: String,
        valueColor: Color = GlassTheme.textPrimary
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Connected Clients

    private var connectedClientsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionLabel("Connected clients")
                Text("\(appState.connectedClients.count)")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(GlassTheme.controlFill)
                    .clipShape(Capsule())

                Spacer()

                Button {
                    Task {
                        isRefreshingClients = true
                        defer { isRefreshingClients = false }
                        await appState.refreshHotspotClients()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isRefreshingClients {
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
                .disabled(isRefreshingClients)
            }

            if appState.connectedClients.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "personalhotspot")
                        .font(.system(size: 22))
                        .foregroundColor(GlassTheme.textTertiary)
                    Text(appState.isHotspotActive
                         ? "No devices currently connected to '\(appState.hotspotSSID)'."
                         : "Turn on hotspot sharing to view connected clients.")
                        .font(.system(size: 12))
                        .foregroundColor(GlassTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Device")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("IP address")
                            .frame(width: 120, alignment: .leading)
                        Text("MAC address")
                            .frame(width: 135, alignment: .leading)
                        Text("Transferred")
                            .frame(width: 90, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(GlassTheme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)

                    ForEach(Array(appState.connectedClients.enumerated()), id: \.element.macAddress) { index, client in
                        if index > 0 {
                            Rectangle()
                                .fill(GlassTheme.separator.opacity(0.45))
                                .frame(height: 1)
                        }
                        HStack(spacing: 12) {
                            HStack(spacing: 7) {
                                Image(systemName: "laptopcomputer.and.iphone")
                                    .font(.system(size: 12))
                                    .foregroundColor(GlassTheme.emeraldGreen)
                                Text(client.hostname ?? "Wireless client")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(GlassTheme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(client.ipAddress)
                                .font(.system(size: 12, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(GlassTheme.cyanSapphire)
                                .frame(width: 120, alignment: .leading)

                            Text(client.macAddress)
                                .font(.system(size: 11.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(GlassTheme.textSecondary)
                                .frame(width: 135, alignment: .leading)

                            Text(SpeedFormatter.formatBytes(totalTransferredBytes(for: client)))
                                .font(.system(size: 12, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(GlassTheme.textPrimary)
                                .frame(width: 90, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                    }
                }
                .background(GlassTheme.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
                )
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Helpers

    private var hotspotStatusText: String {
        guard appState.isHotspotActive else { return "Off" }
        return appState.isRadioBroadcasting ? "Broadcasting" : "Waiting for macOS"
    }

    private var hotspotStatusColor: Color {
        guard appState.isHotspotActive else { return GlassTheme.textTertiary }
        return appState.isRadioBroadcasting ? GlassTheme.emeraldGreen : GlassTheme.amberWarning
    }

    private func totalTransferredBytes(for client: HotspotClient) -> Int64 {
        let (sum, overflow) = client.rxBytes.addingReportingOverflow(client.txBytes)
        if overflow { return Int64.max }
        return Int64(clamping: sum)
    }

    private func copyPassword() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appState.hotspotPassword, forType: .string)
        copiedConfirmation = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedConfirmation = false
        }
    }

    private func generatePassphrase() {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%"
        appState.hotspotPassword = String((0..<12).compactMap { _ in chars.randomElement() })
    }
}
