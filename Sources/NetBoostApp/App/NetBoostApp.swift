import AppKit
import SwiftUI
import NetBoostCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
public struct NetBoostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    public init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    public var body: some Scene {
        WindowGroup("NetBoost", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: GlassTheme.minWindowWidth, minHeight: GlassTheme.minWindowHeight)
                .onAppear {
                    if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "--tab"),
                       ProcessInfo.processInfo.arguments.indices.contains(idx + 1) {
                        let raw = ProcessInfo.processInfo.arguments[idx + 1].lowercased()
                        let matched: AppNavigationTab? = switch raw {
                        case "dashboard": .dashboard
                        case "hotspot": .hotspot
                        case "dispatcher": .dispatcher
                        case "vpn": .vpn
                        case "accelerator": .accelerator
                        case "doctor": .doctor
                        case "aidoctor", "ai": .aiDoctor
                        default: nil
                        }
                        if let matched {
                            appState.selectedTab = matched
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: GlassTheme.defaultWindowWidth,
            height: GlassTheme.defaultWindowHeight
        )
        .commands {
            CommandMenu("Navigate") {
                Button("Dashboard") { appState.selectedTab = .dashboard }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Hotspot Sharing") { appState.selectedTab = .hotspot }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Proxy Dispatcher") { appState.selectedTab = .dispatcher }
                    .keyboardShortcut("3", modifiers: .command)
                Button("VPN & Routing") { appState.selectedTab = .vpn }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Accelerator") { appState.selectedTab = .accelerator }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Campus Doctor") { appState.selectedTab = .doctor }
                    .keyboardShortcut("6", modifiers: .command)
                Button("AI Doctor") { appState.selectedTab = .aiDoctor }
                    .keyboardShortcut("7", modifiers: .command)

                Divider()

                Button("Run Network Auto-Fix") {
                    Task { await appState.executeAutoFix() }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Refresh Telemetry") {
                    Task {
                        await appState.refreshHardwareInterfaces()
                        await appState.runDiagnostics()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarPopupView()
                .environmentObject(appState)
        } label: {
            HStack(spacing: 4) {
                switch appState.menuBarIconStyle {
                case .iconAndSpeed:
                    Image(systemName: appState.appLogoStyle.iconName)
                    if !appState.menuBarThroughputText.isEmpty {
                        Text(appState.menuBarThroughputText)
                            .monospacedDigit()
                    }
                case .compactSpeed:
                    if !appState.menuBarThroughputText.isEmpty {
                        Text(appState.menuBarThroughputText)
                            .monospacedDigit()
                    } else {
                        Image(systemName: appState.appLogoStyle.iconName)
                    }
                case .minimalBadge:
                    Image(systemName: appState.appLogoStyle.iconName)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
