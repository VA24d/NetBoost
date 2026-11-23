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

            // Active Environment Status Pill
            StatusPill(
                text: appState.activeStatePill,
                color: environmentColor(appState.activeEnvironment)
            )

            // Auto-Fix Button & Progress / Summary
            HStack(spacing: 10) {
                if let summary = appState.autoFixSummary {
                    Text(summary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(GlassTheme.emeraldGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(GlassTheme.emeraldGreen.opacity(0.12))
                        .clipShape(Capsule())
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
                        Text(appState.isAutoFixRunning ? "Fixing Network..." : "⚡ Auto-Fix Campus Net")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.amberWarning, isProminent: true))
                .disabled(appState.isAutoFixRunning)
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
