import SwiftUI
import NetBoostCore

public struct HeaderBarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showHelperPopover = false

    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            throughputStrip
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            helperAuthorizationControl

            StatusPill(
                text: appState.activeStatePill,
                color: environmentColor(appState.activeEnvironment),
                showPulse: false
            )
            .layoutPriority(-1)

            if let summary = appState.autoFixSummary {
                HStack(spacing: 4) {
                    Image(systemName: summary.contains("error") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text(summary.contains("error") ? "Fix Failed" : "Fixed")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(summary.contains("error") ? GlassTheme.redAlert : GlassTheme.emeraldGreen)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background((summary.contains("error") ? GlassTheme.redAlert : GlassTheme.emeraldGreen).opacity(0.12))
                .clipShape(Capsule())
                .fixedSize(horizontal: true, vertical: false)
                .help(summary)
            }

            Button {
                Task {
                    await appState.executeAutoFix()
                }
            } label: {
                HStack(spacing: 5) {
                    if appState.isAutoFixRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11.5))
                    }
                    Text(appState.isAutoFixRunning ? "Fixing..." : "Auto-Fix")
                }
            }
            .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.sapphireBlue, isProminent: true))
            .disabled(appState.isAutoFixRunning)
            .help("Set MTU 1280, flush DNS cache, and clear ARP table on \(appState.selectedRepairService)")

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

                Section("App Icon") {
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
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundColor(GlassTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28, height: 28)
            .help("Display options")
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(Color.black.opacity(0.16))
    }

    private var throughputStrip: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(GlassTheme.cyanSapphire)
                Text(SpeedFormatter.formatSpeed(appState.smoothedDownloadBps))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundColor(.white)
            }

            Rectangle()
                .fill(GlassTheme.separator)
                .frame(width: 1, height: 14)

            HStack(spacing: 5) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(GlassTheme.emeraldGreen)
                Text(SpeedFormatter.formatSpeed(appState.smoothedUploadBps))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(GlassTheme.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private var helperAuthorizationControl: some View {
        if !appState.isAuthorized {
            Button {
                Task {
                    await appState.requestUpfrontAuthorization()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11.5))
                    Text("Authorize Once")
                }
            }
            .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire, isProminent: false))
            .help("Install NetBoost's privileged macOS helper service once so no further password prompts appear")
        } else {
            Button {
                showHelperPopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(GlassTheme.emeraldGreen)
                    Text("Authorized")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(GlassTheme.emeraldGreen.opacity(0.12))
                .clipShape(Capsule())
                .fixedSize(horizontal: true, vertical: false)
                .overlay(
                    Capsule().strokeBorder(GlassTheme.emeraldGreen.opacity(0.32), lineWidth: 0.75)
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHelperPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Privileged Helper Active")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Authorized via macOS LaunchDaemon so network tuning, routing, and hotspot actions run without repeat prompts.")
                        .font(.system(size: 11.5))
                        .foregroundColor(GlassTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Re-check") {
                            Task {
                                await appState.refreshAuthorizationStatus()
                            }
                        }
                        Spacer()
                        Button("Uninstall Helper") {
                            showHelperPopover = false
                            Task {
                                await appState.uninstallPrivilegedHelper()
                            }
                        }
                        .foregroundColor(GlassTheme.redAlert)
                    }
                    .controlSize(.small)
                }
                .padding(14)
                .frame(width: 280)
            }
            .help("Privileged helper daemon is active")
        }
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
