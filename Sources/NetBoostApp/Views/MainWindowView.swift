import SwiftUI
import NetBoostCore

public struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hoveredTab: AppNavigationTab?

    public init() {}

    public var body: some View {
        ZStack {
            WindowConfigurator()

            if reduceTransparency {
                GlassTheme.backgroundDark
                    .ignoresSafeArea()
            } else {
                ZStack {
                    VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
                    GlassTheme.backgroundDark.opacity(0.42)
                }
                .ignoresSafeArea()
            }

            HStack(spacing: 0) {
                sidebarView
                    .frame(width: 214)

                Rectangle()
                    .fill(GlassTheme.separator)
                    .frame(width: 1)
                    .ignoresSafeArea(.container, edges: .top)

                VStack(spacing: 0) {
                    HeaderBarView()

                    Rectangle()
                        .fill(GlassTheme.separator)
                        .frame(height: 1)

                    detailContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: GlassTheme.minWindowWidth, minHeight: GlassTheme.minWindowHeight)
    }

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Clearance for native traffic lights in fullSizeContentView window.
            Color.clear.frame(height: 36)

            HStack(spacing: 9) {
                NetBoostBrandMark()
                    .frame(width: 24, height: 24)
                Text("NetBoost")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            ForEach(Array(AppNavigationTab.allCases.enumerated()), id: \.element.id) { index, tab in
                sidebarItem(tab: tab, shortcutNumber: index + 1)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isAuthorized ? GlassTheme.emeraldGreen : GlassTheme.amberWarning)
                        .frame(width: 6, height: 6)
                    Text(appState.isAuthorized ? "Privileged helper ready" : "One-time auth needed")
                        .font(.system(size: 11))
                        .foregroundColor(GlassTheme.textSecondary)
                }
                if !appState.primaryInterface.isEmpty {
                    Text("\(appState.primaryInterface) (\(appState.primaryInterfaceIP))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(GlassTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .background(
            Group {
                if reduceTransparency {
                    GlassTheme.backgroundDark
                } else {
                    VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow)
                        .opacity(0.9)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        switch appState.selectedTab {
        case .dashboard:
            DashboardView()
        case .hotspot:
            HotspotView()
        case .dispatcher:
            DispatcherView()
        case .vpn:
            VPNView()
        case .accelerator:
            AcceleratorView()
        case .doctor:
            DoctorView()
        case .aiDoctor:
            AIDoctorView()
        }
    }

    private func sidebarItem(tab: AppNavigationTab, shortcutNumber: Int) -> some View {
        let isSelected = appState.selectedTab == tab
        let isHovered = hoveredTab == tab
        let badgeColor = liveStatusColor(for: tab)

        return Button {
            appState.selectedTab = tab
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : GlassTheme.textSecondary)
                    .frame(width: 18)

                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : GlassTheme.textSecondary)

                Spacer()

                if let badgeColor {
                    Circle()
                        .fill(badgeColor)
                        .frame(width: 6, height: 6)
                } else if isHovered {
                    Text("⌘\(shortcutNumber)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(GlassTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isSelected
                            ? GlassTheme.sidebarSelectionFill
                            : (isHovered ? Color.white.opacity(0.05) : Color.clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { hovering in
            hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
        }
        .accessibilityLabel(tab.rawValue)
    }

    private func liveStatusColor(for tab: AppNavigationTab) -> Color? {
        switch tab {
        case .hotspot:
            return appState.isHotspotActive ? GlassTheme.emeraldGreen : nil
        case .dispatcher:
            return appState.isProxyActive ? GlassTheme.cyanSapphire : nil
        case .vpn:
            return appState.vpnStatus == .connected ? GlassTheme.emeraldGreen : nil
        case .accelerator:
            if appState.activeDownloadTask?.status == .downloading { return GlassTheme.violetAccent }
            return nil
        case .doctor:
            return appState.activeIssues.isEmpty ? nil : GlassTheme.amberWarning
        case .aiDoctor:
            return appState.isLMStudioConnected ? GlassTheme.emeraldGreen : nil
        case .dashboard:
            return nil
        }
    }
}

private struct NetBoostBrandMark: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let rect = CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
            let squircle = Path(roundedRect: rect, cornerRadius: w * 0.25, style: .continuous)

            context.fill(
                squircle,
                with: .linearGradient(
                    Gradient(colors: [Color(hex: "#0D2448"), Color(hex: "#071122")]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: w, y: h)
                )
            )
            context.stroke(squircle, with: .color(Color.white.opacity(0.18)), lineWidth: 0.8)

            // Twin directional bridge strokes + central velocity chevron.
            var arcLeft = Path()
            arcLeft.move(to: CGPoint(x: w * 0.24, y: h * 0.72))
            arcLeft.addCurve(
                to: CGPoint(x: w * 0.54, y: h * 0.28),
                control1: CGPoint(x: w * 0.24, y: h * 0.42),
                control2: CGPoint(x: w * 0.40, y: h * 0.30)
            )
            context.stroke(
                arcLeft,
                with: .color(GlassTheme.cyanSapphire),
                style: StrokeStyle(lineWidth: w * 0.10, lineCap: .round)
            )

            var chevron = Path()
            chevron.move(to: CGPoint(x: w * 0.44, y: h * 0.70))
            chevron.addLine(to: CGPoint(x: w * 0.76, y: h * 0.46))
            chevron.addLine(to: CGPoint(x: w * 0.52, y: h * 0.30))
            context.stroke(
                chevron,
                with: .color(Color(hex: "#7DD3FC")),
                style: StrokeStyle(lineWidth: w * 0.095, lineCap: .round, lineJoin: .round)
            )

            let node = CGRect(x: w * 0.20, y: h * 0.66, width: w * 0.16, height: w * 0.16)
            context.fill(Path(ellipseIn: node), with: .color(GlassTheme.emeraldGreen))
        }
    }
}
