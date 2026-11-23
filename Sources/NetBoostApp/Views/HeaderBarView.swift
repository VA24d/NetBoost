import SwiftUI
import NetBoostCore

public struct HeaderBarView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        HStack(spacing: 16) {
            // Speedometers: Download & Upload
            HStack(spacing: 20) {
                // Download Speedometer
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(GlassTheme.cyanSapphire)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DOWNLOAD")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(GlassTheme.textTertiary)
                        Text(SpeedFormatter.formatSpeed(appState.smoothedDownloadBps))
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(GlassTheme.cyanSapphire)
                    }
                }

                // Upload Speedometer
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(GlassTheme.emeraldGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UPLOAD")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(GlassTheme.textTertiary)
                        Text(SpeedFormatter.formatSpeed(appState.smoothedUploadBps))
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(GlassTheme.emeraldGreen)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 12)

            Spacer()

            // Privilege Authorization Status / Upfront Authorization Trigger
            if !appState.isAuthorized {
                Button {
                    Task {
                        await appState.requestUpfrontAuthorization()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 11))
                        Text("Authorize")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire, isProminent: false))
                .help("Grant upfront administrator privileges for instant one-click optimizations")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundColor(GlassTheme.emeraldGreen)
                    Text("Authorized")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(GlassTheme.emeraldGreen)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(GlassTheme.emeraldGreen.opacity(0.12))
                .clipShape(Capsule())
                .help("NetBoost privileged helper session is active")
            }

            // Active Environment Status Pill
            StatusPill(
                text: appState.activeStatePill,
                color: environmentColor(appState.activeEnvironment)
            )

            // Auto-Fix Button & Compact Summary Pill
            HStack(spacing: 8) {
                if let summary = appState.autoFixSummary {
                    HStack(spacing: 4) {
                        Image(systemName: summary.contains("error") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        Text(summary.contains("error") ? "Fix Failed" : "Fixed")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(summary.contains("error") ? GlassTheme.redAlert : GlassTheme.emeraldGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((summary.contains("error") ? GlassTheme.redAlert : GlassTheme.emeraldGreen).opacity(0.12))
                    .clipShape(Capsule())
                    .help(summary)
                }

                Button {
                    Task {
                        await appState.executeAutoFix()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if appState.isAutoFixRunning {
                            ProgressView()
                                .controlSize(.small)
                                .colorScheme(.dark)
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 12))
                        }
                        Text(appState.isAutoFixRunning ? "Fixing..." : "⚡ Auto-Fix")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.amberWarning, isProminent: true))
                .disabled(appState.isAutoFixRunning)

                // Status Bar & Logo Customization Menu
                Menu {
                    Section("Status Bar Style") {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            Button {
                                appState.menuBarIconStyle = style
                            } label: {
                                HStack {
                                    Text(style.rawValue)
                                    if appState.menuBarIconStyle == style {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }

                    Section("App Logo Style") {
                        ForEach(AppLogoStyle.allCases) { style in
                            Button {
                                appState.appLogoStyle = style
                            } label: {
                                HStack {
                                    Text(style.rawValue)
                                    if appState.appLogoStyle == style {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 13))
                        .foregroundColor(GlassTheme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24, height: 24)
                .help("Customize Status Bar and Logo style")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(GlassTheme.backgroundDark.opacity(0.4))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.white.opacity(0.08)),
            alignment: .bottom
        )
    }

    private func environmentColor(_ env: NetworkEnvironmentState) -> Color {
        switch env {
        case .campusLAN:
            return GlassTheme.sapphireBlue
        case .cellularHotspot:
            return GlassTheme.amberWarning
        case .externalWiFi:
            return GlassTheme.cyanSapphire
        case .disconnected:
            return GlassTheme.redAlert
        }
    }
}
