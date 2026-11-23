import SwiftUI
import NetBoostCore

@main
public struct NetBoostApp: App {
    @StateObject private var appState = AppState()

    public init() {}

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
                Image(systemName: "bolt.horizontal.circle.fill")
                Text(appState.menuBarThroughputText)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
