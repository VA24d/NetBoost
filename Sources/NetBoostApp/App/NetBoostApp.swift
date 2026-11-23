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
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: GlassTheme.defaultWindowWidth,
            height: GlassTheme.defaultWindowHeight
        )

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
                    }
                case .compactSpeed:
                    if !appState.menuBarThroughputText.isEmpty {
                        Text(appState.menuBarThroughputText)
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
