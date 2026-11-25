import AppKit
import SwiftUI
import NetBoostCore

public struct MenuBarPopupView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    private var primaryInterfaceDisplay: String {
        let name = appState.primaryInterface.isEmpty ? "en10" : appState.primaryInterface
        return "\(name) (\(appState.primaryInterfaceIP))"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: appState.appLogoStyle.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(GlassTheme.cyanSapphire)
                Text("NetBoost")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                StatusPill(
                    text: appState.activeStatePill,
                    color: appState.activeEnvironment.isCampusLAN ? GlassTheme.sapphireBlue : GlassTheme.amberWarning,
                    showPulse: false
                )
            }

            HStack(spacing: 8) {
                Text(appState.menuBarThroughputText.isEmpty
                     ? SpeedFormatter.formatMenuBarThroughput(up: appState.smoothedUploadBps, down: appState.smoothedDownloadBps)
                     : appState.menuBarThroughputText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .foregroundColor(GlassTheme.cyanSapphire)
                Spacer(minLength: 6)
                Text(primaryInterfaceDisplay)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(GlassTheme.textSecondary)
            }
            .padding(9)
            .background(GlassTheme.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Divider()

            VStack(spacing: 5) {
                quickRowButton(
                    icon: "personalhotspot",
                    title: "Hotspot Sharing",
                    status: appState.isHotspotActive ? "\(appState.connectedClients.count) active" : "Off",
                    color: appState.isHotspotActive ? GlassTheme.emeraldGreen : GlassTheme.textTertiary
                ) {
                    Task {
                        do {
                            try await appState.toggleHotspot()
                        } catch {
                            appState.hotspotError = error.localizedDescription
                            appState.appendRepairLog("Hotspot toggle error: \(error.localizedDescription)")
                        }
                    }
                }

                quickRowButton(
                    icon: "arrow.triangle.branch",
                    title: "Proxy Dispatcher",
                    status: appState.isProxyActive ? "Listening" : "Off",
                    color: appState.isProxyActive ? GlassTheme.cyanSapphire : GlassTheme.textTertiary
                ) {
                    Task {
                        do {
                            try await appState.toggleProxy()
                        } catch {
                            appState.proxyError = error.localizedDescription
                            appState.appendRepairLog("Proxy toggle error: \(error.localizedDescription)")
                        }
                    }
                }

                quickRowButton(
                    icon: "lock.shield",
                    title: "VPN (\(appState.activeVPNProfile))",
                    status: appState.vpnStatus == .connected ? "Connected" : "Off",
                    color: appState.vpnStatus == .connected ? GlassTheme.emeraldGreen : GlassTheme.textTertiary
                ) {
                    Task {
                        do {
                            try await appState.toggleVPN()
                        } catch {
                            appState.vpnError = error.localizedDescription
                            appState.appendRepairLog("VPN toggle error: \(error.localizedDescription)")
                        }
                    }
                }

                Button {
                    Task { await appState.executeAutoFix() }
                } label: {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(GlassTheme.amberWarning)
                        Text(appState.isAutoFixRunning ? "Fixing Network..." : "Run Auto-Fix")
                            .foregroundColor(.white)
                        Spacer()
                        if appState.isAutoFixRunning {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(GlassTheme.sapphireBlue.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(appState.isAutoFixRunning)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Menu Bar")
                        .font(.system(size: 11.5))
                        .foregroundColor(GlassTheme.textSecondary)
                    Spacer()
                    Picker("", selection: $appState.menuBarIconStyle) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 145)
                }

                HStack {
                    Text("App Icon")
                        .font(.system(size: 11.5))
                        .foregroundColor(GlassTheme.textSecondary)
                    Spacer()
                    Picker("", selection: $appState.appLogoStyle) {
                        ForEach(AppLogoStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 145)
                }
            }

            Divider()

            HStack {
                Button("Open NetBoost") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(GlassTheme.cyanSapphire)

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(GlassTheme.textSecondary)
            }
        }
        .padding(12)
        .frame(width: 300)
        .preferredColorScheme(.dark)
        .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow))
    }

    private func quickRowButton(
        icon: String,
        title: String,
        status: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.white)
                Spacer(minLength: 6)
                Text(status)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(GlassTheme.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
