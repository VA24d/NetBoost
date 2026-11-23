import AppKit
import SwiftUI

/// VisualEffectBackground provides a native AppKit behind-window translucent Liquid Glass backdrop.
public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .underWindowBackground,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

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
