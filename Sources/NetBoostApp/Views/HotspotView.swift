import SwiftUI
import NetBoostCore

public struct HotspotView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showPassword: Bool = false
    @State private var copiedConfirmation: Bool = false

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("802.1X Hotspot Sharing Engine")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("Share authenticated Wired Ethernet (en10) over Wi-Fi (en0) with NAT & DHCP")
                            .font(.system(size: 12))
                            .foregroundColor(GlassTheme.textSecondary)
                    }
                    Spacer()
                    StatusPill(
                        text: appState.isHotspotActive ? "HOTSPOT ACTIVE" : "STOPPED",
                        color: appState.isHotspotActive ? GlassTheme.emeraldGreen : GlassTheme.textTertiary,
                        showPulse: appState.isHotspotActive
                    )
                }

                if let err = appState.hotspotError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(GlassTheme.amberWarning)
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GlassTheme.amberWarning.opacity(0.15))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(GlassTheme.amberWarning.opacity(0.4), lineWidth: 1)
                    )
                }

                // Master Hotspot Toggle Card
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Wired-to-Wireless Sharing")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                            Text("Routes packets between \(appState.upstreamInterface) (Uplink) and \(appState.downstreamInterface) (Access Point)")
                                .font(.system(size: 11))
                                .foregroundColor(GlassTheme.textSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { appState.isHotspotActive },
                            set: { _ in
                                Task {
                                    try? await appState.toggleHotspot()
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .disabled(!appState.canEnableHotspot)
                        .help(appState.canEnableHotspot ? "Toggle Hotspot NAT" : "Requires active Ethernet (en10) to enable sharing")
                    }

                    HStack {
                        Button {
                            appState.openSystemSharingSettings()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "gearshape")
                                Text("Open macOS Internet Sharing Settings")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(GlassTheme.cyanNeon)
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }

                    if !appState.canEnableHotspot {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundColor(GlassTheme.amberWarning)
                            Text("Upstream Ethernet (en10) must be plugged in and authenticated before hotspot can be started.")
                                .font(.system(size: 11))
                                .foregroundColor(GlassTheme.amberWarning)
                        }
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 14, strokeColor: appState.isHotspotActive ? GlassTheme.emeraldGreen.opacity(0.5) : Color.white.opacity(0.1))

                // Hotspot Configuration Card
                VStack(alignment: .leading, spacing: 14) {
                    Text("Access Point & Security Configuration")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("NETWORK SSID")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(GlassTheme.textTertiary)
                            TextField("SSID", text: $appState.hotspotSSID)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .padding(8)
                                .background(Color.black.opacity(0.3))
                                .cornerRadius(8)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("HOTSPOT PASSWORD")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(GlassTheme.textTertiary)
                                Spacer()
                                if copiedConfirmation {
                                    Text("Copied!")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(GlassTheme.emeraldGreen)
                                }
                            }

                            HStack(spacing: 6) {
                                if showPassword {
                                    TextField("Password", text: $appState.hotspotPassword)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13, design: .monospaced))
                                } else {
                                    SecureField("Password", text: $appState.hotspotPassword)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13, design: .monospaced))
                                }

                                // View/Hide Password Button
                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(showPassword ? GlassTheme.cyanNeon : GlassTheme.textTertiary)
                                }
                                .buttonStyle(.plain)
                                .help(showPassword ? "Hide password" : "View password")

                                // Copy Password Button
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(appState.hotspotPassword, forType: .string)
                                    copiedConfirmation = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        copiedConfirmation = false
                                    }
                                } label: {
                                    Image(systemName: "doc.on.doc.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(GlassTheme.cyanSapphire)
                                }
                                .buttonStyle(.plain)
                                .help("Copy password to clipboard")

                                // Generate Random Secure Password Button
                                Button {
                                    let chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%"
                                    appState.hotspotPassword = String((0..<12).compactMap { _ in chars.randomElement() })
                                } label: {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 12))
                                        .foregroundColor(GlassTheme.emeraldGreen)
                                }
                                .buttonStyle(.plain)
                                .help("Generate random secure password")
                            }
                            .padding(8)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(8)
                        }
                    }

                    // Security Type Picker (WPA3 Support)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SECURITY PROTOCOL")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(GlassTheme.textTertiary)

                        Picker("Security", selection: $appState.hotspotSecurityType) {
                            ForEach(HotspotSecurityType.allCases) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Divider().background(Color.white.opacity(0.08))

                    // Subnet & Gateway Details
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SUBNET").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                            Text("192.168.2.0/24").font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("GATEWAY IP").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                            Text("192.168.2.1").font(.system(size: 12, design: .monospaced)).foregroundColor(GlassTheme.emeraldGreen)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DHCP LEASE POOL").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                            Text("192.168.2.10 – 192.168.2.100").font(.system(size: 12, design: .monospaced)).foregroundColor(GlassTheme.cyanSapphire)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PF NAT ANCHOR").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                            Text("netboost").font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                        }
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 14)

                // Connected Clients Table
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Connected Wireless Clients (\(appState.connectedClients.count))")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Button {
                            Task {
                                await appState.refreshHotspotClients()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("Refresh ARP")
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(GlassTheme.cyanNeon)
                    }

                    if appState.connectedClients.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 24))
                                .foregroundColor(GlassTheme.textTertiary)
                            Text(appState.isHotspotActive ? "No clients currently connected to the hotspot." : "Start hotspot to accept client connections.")
                                .font(.system(size: 12))
                                .foregroundColor(GlassTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(appState.connectedClients, id: \.macAddress) { client in
                                HStack {
                                    Image(systemName: "ipad.and.iphone")
                                        .foregroundColor(GlassTheme.emeraldGreen)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(client.hostname ?? "Wireless Device")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                        Text(client.macAddress)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(GlassTheme.textTertiary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(client.ipAddress)
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .foregroundColor(GlassTheme.cyanSapphire)
                                        Text("TX: \(SpeedFormatter.formatSpeed(Double(client.txBytes)))  RX: \(SpeedFormatter.formatSpeed(Double(client.rxBytes)))")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(GlassTheme.textSecondary)
                                    }
                                }
                                .padding(10)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 14)
            }
            .padding(20)
        }
    }
}
