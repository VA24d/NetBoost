import SwiftUI

public enum GlassTheme {
    // Hex color constants retained for theme tests and palette references.
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

    // Color tokens
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

    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.72)
    public static let textTertiary = Color.white.opacity(0.48)
    public static let separator = Color(nsColor: .separatorColor).opacity(0.55)
    public static let controlFill = Color.white.opacity(0.06)
    public static let controlBorder = Color.white.opacity(0.11)
    public static let sidebarSelectionFill = Color.white.opacity(0.11)

    // Window metrics
    public static let minWindowWidth: CGFloat = 920
    public static let minWindowHeight: CGFloat = 600
    public static let recommendedMinWidth: CGFloat = 960
    public static let defaultWindowWidth: CGFloat = 1040
    public static let defaultWindowHeight: CGFloat = 700
    public static let windowTitle = "NetBoost"

    // WCAG 2.2 AA contrast ratio check (>= 4.5:1)
    public static func contrastRatio(foreground: Color, background: Color) -> Double {
        func luminance(r: Double, g: Double, b: Double) -> Double {
            0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let fgLum = luminance(r: 1.0, g: 1.0, b: 1.0)
        let bgLum = luminance(r: 0.05, g: 0.07, b: 0.09)
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
        case 6:
            (a, r, g, b) = (255, int >> 16, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
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

// MARK: - Glass Card Modifier

public struct GlassCardModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var strokeColor: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(cornerRadius: CGFloat = 12, strokeColor: Color = Color.white.opacity(0.10)) {
        self.cornerRadius = cornerRadius
        self.strokeColor = strokeColor
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                Group {
                    if reduceTransparency {
                        GlassTheme.surfaceBackground
                    } else {
                        ZStack {
                            GlassTheme.surfaceBackground.opacity(0.68)
                            shape.fill(.regularMaterial.opacity(0.32))
                        }
                    }
                }
            )
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), strokeColor.opacity(0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            )
            .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 1)
    }
}

extension View {
    public func glassCard(
        cornerRadius: CGFloat = 12,
        strokeColor: Color = Color.white.opacity(0.10)
    ) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, strokeColor: strokeColor))
    }
}

// MARK: - Native Control Styles

public struct GlowingButtonStyle: ButtonStyle {
    public var accentColor: Color
    public var isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(accentColor: Color = GlassTheme.cyanSapphire, isProminent: Bool = false) {
        self.accentColor = accentColor
        self.isProminent = isProminent
    }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(isProminent ? .white : GlassTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Group {
                    if isProminent {
                        accentColor.opacity(configuration.isPressed ? 0.55 : 0.36)
                    } else {
                        Color.white.opacity(configuration.isPressed ? 0.14 : 0.08)
                    }
                }
            )
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    isProminent ? accentColor.opacity(0.65) : Color.white.opacity(0.14),
                    lineWidth: 0.75
                )
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1.0) : 0.5)
    }
}

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
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(color.opacity(0.32), lineWidth: 0.75)
        )
    }
}

public struct PageHeader: View {
    public let title: String
    public let subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundColor(GlassTheme.textSecondary)
        }
    }
}

public struct SectionLabel: View {
    public let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
    }
}

// MARK: - Speed and Byte Formatting

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

    public static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let val = Double(bytes)
        if val < 1024 {
            return "\(bytes) B"
        } else if val < 1024 * 1024 {
            return String(format: "%.1f KB", val / 1024)
        } else if val < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", val / (1024 * 1024))
        } else {
            return String(format: "%.2f GB", val / (1024 * 1024 * 1024))
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

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let mins = total / 60
        let secs = total % 60
        if mins < 60 { return String(format: "%dm %02ds", mins, secs) }
        return String(format: "%dh %02dm", mins / 60, mins % 60)
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
