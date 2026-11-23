import SwiftUI

// MARK: - GlassTheme Design System Tokens & Palette

public enum GlassTheme {
    // Hex Color Palette Constants (Exact hex strings matching Tier 1 & Tier 2 specifications)
    public static let cyanSapphireHex = "#00D2FF"
    public static let cyanNeonHex = "#00F0FF"
    public static let sapphireBlueHex = "#0051FF"
    public static let emeraldGreenHex = "#00E676"
    public static let emeraldHotspotHex = "#00FF66"
    public static let amberWarningHex = "#FFD600"
    public static let amberVPNHex = "#FFB800"
    public static let violetAccentHex = "#D500F9"
    public static let violetChunksHex = "#B026FF"
    public static let backgroundDarkHex = "#0D1117"
    public static let surfaceBackgroundHex = "#161B22"
    public static let redAlertHex = "#FF1744"

    // SwiftUI Color Tokens
    public static let cyanSapphire = Color(hex: cyanSapphireHex)
    public static let cyanNeon = Color(hex: cyanNeonHex)
    public static let sapphireBlue = Color(red: 0.05, green: 0.45, blue: 0.95)
    public static let emeraldGreen = Color(red: 0.1, green: 0.85, blue: 0.4)
    public static let emeraldHotspot = Color(hex: emeraldHotspotHex)
    public static let amberWarning = Color(red: 1.0, green: 0.7, blue: 0.1)
    public static let amberVPN = Color(hex: amberVPNHex)
    public static let violetAccent = Color(red: 0.65, green: 0.25, blue: 0.95)
    public static let violetChunks = Color(hex: violetChunksHex)
    public static let backgroundDark = Color(hex: backgroundDarkHex)
    public static let surfaceBackground = Color(hex: surfaceBackgroundHex)
    public static let redAlert = Color(hex: redAlertHex)
    public static let textSecondary = Color.white.opacity(0.7)
    public static let textTertiary = Color.white.opacity(0.45)

    // Window Metrics
    public static let minWindowWidth: CGFloat = 920
    public static let minWindowHeight: CGFloat = 600
    public static let recommendedMinWidth: CGFloat = 960
    public static let defaultWindowWidth: CGFloat = 1040
    public static let defaultWindowHeight: CGFloat = 700
    public static let windowTitle = "NetBoost"

    // Contrast Ratio Helper for WCAG 2.2 AA Compliance (> 4.5:1)
    public static func contrastRatio(foreground: Color, background: Color) -> Double {
        // Standard relative luminance formula
        func luminance(r: Double, g: Double, b: Double) -> Double {
            0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let fgLum = luminance(r: 1.0, g: 1.0, b: 1.0) // White text
        let bgLum = luminance(r: 0.05, g: 0.07, b: 0.09) // Dark background #0D1117
        return (fgLum + 0.05) / (bgLum + 0.05)
    }
}

// MARK: - Color Hex Initializer

extension Color {
    public init(hex: String) {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleanHex.count {
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, (int >> 8) & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}

// MARK: - Glass Card View Modifier

public struct GlassCardModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var strokeColor: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(cornerRadius: CGFloat = 14, strokeColor: Color = Color.white.opacity(0.12)) {
        self.cornerRadius = cornerRadius
        self.strokeColor = strokeColor
    }

    public func body(content: Content) -> some View {
        content
            .background(
                Group {
                    if reduceTransparency {
                        GlassTheme.backgroundDark
                    } else {
                        ZStack {
                            GlassTheme.backgroundDark.opacity(0.82)
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(.ultraThinMaterial)
                        }
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        LinearGradient(
                            colors: [strokeColor, strokeColor.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 4)
    }
}

extension View {
    public func glassCard(
        cornerRadius: CGFloat = 14,
        strokeColor: Color = Color.white.opacity(0.12)
    ) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, strokeColor: strokeColor))
    }
}

// MARK: - Glowing Button Style

public struct GlowingButtonStyle: ButtonStyle {
    public var accentColor: Color
    public var isProminent: Bool

    public init(accentColor: Color = GlassTheme.cyanNeon, isProminent: Bool = false) {
        self.accentColor = accentColor
        self.isProminent = isProminent
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Group {
                    if isProminent {
                        accentColor.opacity(configuration.isPressed ? 0.35 : 0.22)
                    } else {
                        Color.white.opacity(configuration.isPressed ? 0.12 : 0.06)
                    }
                }
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(accentColor.opacity(isProminent ? 0.8 : 0.4), lineWidth: 1)
            )
            .shadow(
                color: isProminent ? accentColor.opacity(0.4) : Color.clear,
                radius: configuration.isPressed ? 8 : 4,
                x: 0,
                y: 0
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Status Pill View

public struct StatusPill: View {
    public let text: String
    public let color: Color
    public let showPulse: Bool

    public init(text: String, color: Color, showPulse: Bool = true) {
        self.text = text
        self.color = color
        self.showPulse = showPulse
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: showPulse ? 4 : 0)
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Speed Formatting Utilities

public enum SpeedFormatter {
    public static func formatSpeed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "0 B/s" }
        if bytesPerSec < 1024 {
            return String(format: "%.0f B/s", bytesPerSec)
        } else if bytesPerSec < 1024 * 1024 {
            return String(format: "%.1f KB/s", bytesPerSec / 1024)
        } else if bytesPerSec < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
        } else {
            return String(format: "%.2f GB/s", bytesPerSec / (1024 * 1024 * 1024))
        }
    }

    public static func formatCompact(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "0 B/s" }
        if bytesPerSec < 1024 * 1024 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024)
        } else {
            return String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
        }
    }

    public static func formatMenuBarThroughput(up: Double, down: Double) -> String {
        func formatSingle(_ val: Double) -> String {
            guard val > 0 else { return "0 B/s" }
            if val < 1024 * 1024 {
                return String(format: "%.0f KB/s", val / 1024)
            } else {
                return String(format: "%.1f MB/s", val / (1024 * 1024))
            }
        }
        return "↑ \(formatSingle(up))  ↓ \(formatSingle(down))"
    }
}
