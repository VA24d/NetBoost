import AppKit
import SwiftUI
import NetBoostCore

public struct DispatcherView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedCopyPort: Int = 1080

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Per-App & Per-Job Proxy Dispatcher")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("Bind local proxy listener ports to specific interfaces with kernel route pinning")
                            .font(.system(size: 12))
                            .foregroundColor(GlassTheme.textSecondary)
                    }
                    Spacer()
                    StatusPill(
                        text: appState.isProxyActive ? "DISPATCHER ACTIVE" : "STOPPED",
                        color: appState.isProxyActive ? GlassTheme.cyanNeon : GlassTheme.textTertiary,
                        showPulse: appState.isProxyActive
                    )
                }

                // Master Toggle & Shell Snippet Card
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Multi-Interface Proxy Engine")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                            Text("Listens on 127.0.0.1 across 3 dedicated SOCKS5/HTTP egress ports")
                                .font(.system(size: 11))
                                .foregroundColor(GlassTheme.textSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { appState.isProxyActive },
                            set: { _ in
                                Task {
                                    try? await appState.toggleProxy()
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                    }

                    Divider().background(Color.white.opacity(0.08))

                    // Shell Environment Snippet Generator
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CLI ENVIRONMENT HELPER SNIPPET")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(GlassTheme.textTertiary)

                        HStack(spacing: 12) {
                            Picker("Port", selection: $selectedCopyPort) {
                                Text("Port 1080 (en10 Campus)").tag(1080)
                                Text("Port 1081 (en0 Wi-Fi)").tag(1081)
                                Text("Port 1082 (Auto)").tag(1082)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 320)

                            Spacer()

                            Button {
                                let snippet = "export ALL_PROXY=socks5://127.0.0.1:\(selectedCopyPort)"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(snippet, forType: .string)
                                appState.copiedSnippetMessage = "Copied: \(snippet)"
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc")
                                    Text("Copy Shell Snippet")
                                }
                            }
                            .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanNeon))
                        }

                        // Preview Box
                        HStack {
                            Text("export ALL_PROXY=socks5://127.0.0.1:\(selectedCopyPort)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(GlassTheme.cyanSapphire)
                            Spacer()
                            if let copied = appState.copiedSnippetMessage {
                                Text(copied)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(GlassTheme.emeraldGreen)
                            }
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.35))
                        .cornerRadius(8)
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 14, strokeColor: appState.isProxyActive ? GlassTheme.cyanNeon.opacity(0.5) : Color.white.opacity(0.1))

                // Port Allocation Cards
                Text("Configured Dispatcher Ports")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)

                HStack(spacing: 14) {
                    portCard(
                        port: 1080,
                        interface: "en10",
                        purpose: "Wired Campus Direct",
                        targetSubnets: "10.8.0.0/16, 10.4.0.0/16",
                        accentColor: GlassTheme.sapphireBlue
                    )

                    portCard(
                        port: 1081,
                        interface: "en0",
                        purpose: "Cellular / External Wi-Fi",
                        targetSubnets: "0.0.0.0/0 (Default Route)",
                        accentColor: GlassTheme.emeraldGreen
                    )

                    portCard(
                        port: 1082,
                        interface: "auto",
                        purpose: "Dynamic Load-Balanced",
                        targetSubnets: "Failover & Bonded Routing",
                        accentColor: GlassTheme.violetAccent
                    )
                }

                // Active Connections Table
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Active SOCKS5 / HTTP Connections (\(appState.activeConnections.count))")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                    }

                    if appState.activeConnections.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 24))
                                .foregroundColor(GlassTheme.textTertiary)
                            Text(appState.isProxyActive ? "No active connections routed through dispatcher." : "Start proxy dispatcher to route connections.")
                                .font(.system(size: 12))
                                .foregroundColor(GlassTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(appState.activeConnections) { conn in
                                HStack {
                                    Circle()
                                        .fill(GlassTheme.cyanNeon)
                                        .frame(width: 6, height: 6)
                                    Text("\(conn.clientAddress)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(GlassTheme.textSecondary)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 10))
                                        .foregroundColor(GlassTheme.textTertiary)
                                    Text("\(conn.targetHost):\(conn.targetPort)")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Spacer()
                                    StatusPill(
                                        text: conn.egressInterface,
                                        color: conn.egressInterface == "en10" ? GlassTheme.sapphireBlue : GlassTheme.emeraldGreen,
                                        showPulse: false
                                    )
                                    Text("↓ \(SpeedFormatter.formatSpeed(Double(conn.bytesRead)))  ↑ \(SpeedFormatter.formatSpeed(Double(conn.bytesWritten)))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(GlassTheme.textSecondary)
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

    private func portCard(
        port: Int,
        interface: String,
        purpose: String,
        targetSubnets: String,
        accentColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Port \(port)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(accentColor)
                Spacer()
                StatusPill(
                    text: interface,
                    color: accentColor,
                    showPulse: appState.isProxyActive
                )
            }

            Text(purpose)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            Text("Subnets: \(targetSubnets)")
                .font(.system(size: 10))
                .foregroundColor(GlassTheme.textSecondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, strokeColor: accentColor.opacity(0.35))
    }
}
