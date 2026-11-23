import SwiftUI
import NetBoostCore

public struct VPNView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Context-Aware VPN & Split Routing")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("Dynamic OpenVPN automation with Passepartout profile and campus LAN collision avoidance")
                            .font(.system(size: 12))
                            .foregroundColor(GlassTheme.textSecondary)
                    }
                    Spacer()
                    StatusPill(
                        text: appState.vpnStatus.rawValue.uppercased(),
                        color: statusColor(appState.vpnStatus),
                        showPulse: appState.vpnStatus == .connected
                    )
                }

                // Route Collision Warning Banner
                if !appState.routeConflicts.isEmpty || (appState.activeEnvironment.isCampusLAN && appState.vpnStatus == .connected) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.system(size: 22))
                            .foregroundColor(GlassTheme.amberWarning)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Campus LAN Route Collision Detected")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(GlassTheme.amberWarning)
                            Text("VPN profile pushes 10.1.0.0/16 over tunnel, overlapping campus LAN (10.1.36.0/22). Campus traffic is pinned directly to en10 to prevent gateway disconnects.")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        Spacer()
                        Button("Inspect Pinning") {
                            appState.checkRouteConflicts()
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.amberWarning))
                    }
                    .padding(14)
                    .background(GlassTheme.amberWarning.opacity(0.12))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(GlassTheme.amberWarning.opacity(0.4), lineWidth: 1)
                    )
                }

                // Profile Status Card
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 24))
                            .foregroundColor(GlassTheme.sapphireBlue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.activeVPNProfile)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                            Text("Passepartout OpenVPN Profile · Auto-Quarantine Active")
                                .font(.system(size: 11))
                                .foregroundColor(GlassTheme.textSecondary)
                        }
                        Spacer()
                        Button {
                            Task {
                                try? await appState.toggleVPN()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: appState.vpnStatus == .connected ? "stop.fill" : "play.fill")
                                Text(appState.vpnStatus == .connected ? "Disconnect" : "Connect")
                            }
                        }
                        .buttonStyle(
                            GlowingButtonStyle(
                                accentColor: appState.vpnStatus == .connected ? GlassTheme.redAlert : GlassTheme.emeraldGreen,
                                isProminent: true
                            )
                        )
                    }

                    Divider().background(Color.white.opacity(0.08))

                    // Context Automation Toggle
                    Toggle("Automate VPN by Network Context (Cellular = Connected, Campus LAN = Split/Direct)", isOn: $appState.isVPNAutomationEnabled)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .toggleStyle(.switch)
                }
                .padding(16)
                .glassCard(cornerRadius: 14, strokeColor: GlassTheme.sapphireBlue.opacity(0.4))

                // Visual Routing Map
                VStack(alignment: .leading, spacing: 12) {
                    Text("Split Routing Architecture Map")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)

                    HStack(spacing: 16) {
                        // Direct Route Box
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Circle().fill(GlassTheme.sapphireBlue).frame(width: 8, height: 8)
                                Text("DIRECT (Campus LAN)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(GlassTheme.sapphireBlue)
                            }
                            Text("10.1.0.0/16 · 10.8.0.0/16 · 10.4.0.0/16")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white)
                            Text("Egress: Wired Ethernet en10 (Bypasses VPN)")
                                .font(.system(size: 10))
                                .foregroundColor(GlassTheme.textSecondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 10, strokeColor: GlassTheme.sapphireBlue.opacity(0.3))

                        // Tunneled Route Box
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Circle().fill(GlassTheme.amberWarning).frame(width: 8, height: 8)
                                Text("TUNNELED (Encrypted)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(GlassTheme.amberWarning)
                            }
                            Text("0.0.0.0/0 (Default Internet Routes)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white)
                            Text("Egress: utun3 / Passepartout OpenVPN")
                                .font(.system(size: 10))
                                .foregroundColor(GlassTheme.textSecondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 10, strokeColor: GlassTheme.amberWarning.opacity(0.3))
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 14)

                // Network Service Order Priority List
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Network Service Order Priority")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Button("Prioritize Wired Ethernet") {
                            Task {
                                let ordered = ["USB 10/100 LAN", "Wi-Fi", "Thunderbolt Bridge"]
                                try? await appState.reorderServices(ordered: ordered)
                            }
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanNeon))
                    }

                    VStack(spacing: 6) {
                        ForEach(Array(appState.networkServiceOrder.enumerated()), id: \.offset) { index, service in
                            HStack {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(index == 0 ? GlassTheme.cyanNeon : GlassTheme.textTertiary)
                                    .frame(width: 24)
                                Text(service)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                Spacer()
                                StatusPill(
                                    text: index == 0 ? "PRIMARY" : "FALLBACK",
                                    color: index == 0 ? GlassTheme.emeraldGreen : GlassTheme.textTertiary,
                                    showPulse: false
                                )
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(8)
                        }
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 14)
            }
            .padding(20)
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
