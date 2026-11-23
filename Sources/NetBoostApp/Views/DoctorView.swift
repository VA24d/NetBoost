import AppKit
import SwiftUI
import NetBoostCore

public struct DoctorView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    private let endpointMetadata: [(host: String, label: String, role: String)] = [
        ("10.1.36.1", "Switch Gateway", "Local Switch"),
        ("10.8.0.80", "Campus Core", "Core Gateway"),
        ("turing.iiit.ac.in", "Turing HPC", "Campus HPC Cluster"),
        ("google.com", "Google Web", "External Public DNS"),
        ("claude.com", "Claude AI Cloud", "AI Cloud Service")
    ]

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Campus Diagnostics & Network Doctor")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("Real-time switch latency, captive portal detection, and automated remediation tools")
                            .font(.system(size: 12))
                            .foregroundColor(GlassTheme.textSecondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            await appState.runDiagnostics()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Run Full Scan")
                        }
                    }
                    .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanNeon))
                }

                // Captive Portal Alert Banner
                if appState.captivePortalStatus == .detected || appState.captivePortalStatus == .redirecting {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 24))
                            .foregroundColor(GlassTheme.amberWarning)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Captive Portal Detected")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(GlassTheme.amberWarning)
                            Text("Campus network requires web authentication. Internet traffic is currently intercepted.")
                                .font(.system(size: 11))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        Button("Open Login Page") {
                            if let url = URL(string: "http://captive.apple.com") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.amberWarning, isProminent: true))
                    }
                    .padding(14)
                    .background(GlassTheme.amberWarning.opacity(0.15))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(GlassTheme.amberWarning.opacity(0.4), lineWidth: 1)
                    )
                }

                // 5 Endpoint RTT Latency Dials
                Text("Target Infrastructure Latency & Reachability")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)

                HStack(spacing: 12) {
                    ForEach(endpointMetadata, id: \.host) { item in
                        let probe = appState.endpointRTTs[item.host]
                        latencyDialCard(
                            host: item.host,
                            label: item.label,
                            role: item.role,
                            probe: probe
                        )
                    }
                }

                // Manual Remediation Actions
                VStack(alignment: .leading, spacing: 12) {
                    Text("Manual Network Remediation Actions")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)

                    HStack(spacing: 10) {
                        Button("Flush DNS Cache") {
                            Task { try? await appState.manualFlushDNS() }
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanNeon))

                        Button("Flush ARP Table") {
                            Task { try? await appState.manualFlushARP() }
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanNeon))

                        Button("Set MTU 1280") {
                            Task { try? await appState.manualFixMTU() }
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.amberWarning))

                        Button("Disable IPv6") {
                            Task { try? await appState.manualDisableIPv6() }
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.textSecondary))

                        Button("Reset DNS") {
                            Task { try? await appState.manualResetDNS() }
                        }
                        .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.textSecondary))
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 14)

                // Live Repair Console Log
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Live Diagnostic & Repair Console")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Button("Clear Console") {
                            appState.clearRepairLogs()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundColor(GlassTheme.textTertiary)
                    }

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            if appState.repairLogs.isEmpty {
                                Text("No repair events logged. Diagnostics and auto-fix actions will appear here.")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(GlassTheme.textTertiary)
                            } else {
                                ForEach(Array(appState.repairLogs.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(lineColor(for: line))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(10)
                    }
                    .frame(height: 180)
                    .background(Color.black.opacity(0.45))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .padding(16)
                .glassCard(cornerRadius: 14)
            }
            .padding(20)
        }
    }

    private func latencyDialCard(
        host: String,
        label: String,
        role: String,
        probe: ProbeResult?
    ) -> some View {
        let latency = probe?.latencyMs ?? 0
        let isReachable = probe?.isReachable ?? false
        let dialColor = latencyColor(latency: latency, isReachable: isReachable)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(dialColor)
                    .frame(width: 8, height: 8)
                Spacer()
                Text(role)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(GlassTheme.textTertiary)
            }

            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(host)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(GlassTheme.textSecondary)
                .lineLimit(1)

            Divider().background(Color.white.opacity(0.06))

            if isReachable {
                Text(String(format: "%.1f ms", latency))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(dialColor)
            } else {
                Text(probe == nil ? "Probing..." : "Offline")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(probe == nil ? GlassTheme.textTertiary : GlassTheme.redAlert)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 10, strokeColor: dialColor.opacity(0.3))
    }

    private func latencyColor(latency: Double, isReachable: Bool) -> Color {
        guard isReachable else { return GlassTheme.redAlert }
        if latency < 50.0 {
            return GlassTheme.emeraldGreen  // <50ms: Green #00E676
        } else if latency < 150.0 {
            return GlassTheme.amberWarning  // 50-150ms: Amber #FFD600
        } else {
            return GlassTheme.redAlert      // >=150ms: Red #FF1744
        }
    }

    private func lineColor(for line: String) -> Color {
        if line.contains("❌") || line.contains("error") || line.contains("failed") {
            return GlassTheme.redAlert
        } else if line.contains("✓") || line.contains("🎉") {
            return GlassTheme.emeraldGreen
        } else if line.contains("⚠️") || line.contains("debounced") {
            return GlassTheme.amberWarning
        } else {
            return Color.white.opacity(0.85)
        }
    }
}
