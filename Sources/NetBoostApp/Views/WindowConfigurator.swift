import AppKit
import SwiftUI

/// WindowConfigurator provides zero-overhead AppKit bridge customization for the root NSWindow.
/// Enables liquid glass wallpaper translucency, hidden titlebar, and minimum window constraints.
public struct WindowConfigurator: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(
                width: GlassTheme.minWindowWidth,
                height: GlassTheme.minWindowHeight
            )
            window.hasShadow = true
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        // No-op for static window configuration
    }
}
