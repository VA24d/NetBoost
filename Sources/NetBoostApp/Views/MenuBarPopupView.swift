import AppKit
import SwiftUI
import NetBoostCore

public struct MenuBarPopupView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    private var primaryInterfaceDisplay: String {
        let name = appState.activeEnvironment.isCampusLAN ? "Ethernet" : "Wi-Fi"
        return "\(name): \(appState.primaryInterfaceIP)"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Live Speed Indicator Header
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(GlassTheme.cyanNeon)
                    Text("NetBoost Network Controller")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                    StatusPill(
                        text: appState.activeStatePill,
                        color: appState.activeEnvironment.isCampusLAN ? GlassTheme.sapphireBlue : GlassTheme.amberWarning
                    )
                }

                HStack(spacing: 16) {
                    Text(appState.menuBarThroughputText)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(GlassTheme.cyanSapphire)
                }
            }
            .padding(10)
            .glassCard(cornerRadius: 10)

            // Primary Interface Info
            HStack {
                Text("Primary Interface:")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(GlassTheme.textSecondary)
                Spacer()
                Text(primaryInterfaceDisplay)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 4)

            Divider().background(Color.white.opacity(0.1))

            // Quick Actions & Toggles
            VStack(spacing: 6) {
                // Toggle Hotspot
                Button {
                    Task { try? await appState.toggleHotspot() }
                } label: {
                    HStack {
                        Image(systemName: "personalhotspot")
                            .foregroundColor(appState.isHotspotActive ? GlassTheme.emeraldGreen : GlassTheme.textTertiary)
                        Text("Toggle Hotspot")
                        Spacer()
                        Text(appState.isHotspotActive ? "ON" : "OFF")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(appState.isHotspotActive ? GlassTheme.emeraldGreen : GlassTheme.textTertiary)
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Toggle VPN
                Button {
                    Task { try? await appState.toggleVPN() }
                } label: {
                    HStack {
                        Image(systemName: "lock.shield")
                            .foregroundColor(appState.vpnStatus == .connected ? GlassTheme.emeraldGreen : GlassTheme.textTertiary)
                        Text("Toggle VPN")
                        Spacer()
                        Text(appState.vpnStatus == .connected ? "CONNECTED" : "OFF")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(appState.vpnStatus == .connected ? GlassTheme.emeraldGreen : GlassTheme.textTertiary)
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Auto-Fix Network Trigger
                Button {
                    Task { await appState.executeAutoFix() }
                } label: {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(GlassTheme.amberWarning)
                        Text(appState.isAutoFixRunning ? "Fixing Network..." : "Auto-Fix Network")
                            .foregroundColor(GlassTheme.amberWarning)
                        Spacer()
                        if appState.isAutoFixRunning {
                            ProgressView().controlSize(.small).colorScheme(.dark)
                        }
                    }
                    .padding(8)
                    .background(GlassTheme.amberWarning.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(appState.isAutoFixRunning)
            }

            // Status Bar & Logo Pickers
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Menu Bar Style:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(GlassTheme.textSecondary)
                    Spacer()
                    Picker("", selection: $appState.menuBarIconStyle) {
                        ForEach(MenuBarIconStyle.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }

                HStack {
                    Text("App Logo Style:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(GlassTheme.textSecondary)
                    Spacer()
                    Picker("", selection: $appState.appLogoStyle) {
                        ForEach(AppLogoStyle.allCases) { l in
                            Text(l.rawValue).tag(l)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
            }
            .padding(8)
            .background(Color.white.opacity(0.04))
            .cornerRadius(8)

            Divider().background(Color.white.opacity(0.1))

            // App Window & Lifecycle Controls
            HStack {
                Button("Open NetBoost Window") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(GlassTheme.cyanNeon)

                Spacer()

                Button("Quit NetBoost") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(GlassTheme.redAlert)
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
        .frame(width: 320)
        .background(GlassTheme.backgroundDark.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}
