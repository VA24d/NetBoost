import SwiftUI
import NetBoostCore

public struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    public var body: some View {
        ZStack {
            // AppKit Window Configurator (Hidden title bar, translucency, min dimensions)
            WindowConfigurator()

            // Root Liquid Glass Translucent Background
            if reduceTransparency {
                GlassTheme.backgroundDark
                    .ignoresSafeArea()
            } else {
                ZStack {
                    VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
                    LinearGradient(
                        colors: [
                            GlassTheme.backgroundDark.opacity(0.35),
                            GlassTheme.backgroundDark.opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .ignoresSafeArea()
            }

            // Main Content Layout
            VStack(spacing: 0) {
                // Persistent Top Header Bar
                HeaderBarView()

                // Split Body: Left Sidebar + Tab View Area
                HStack(spacing: 0) {
                    // Left Navigation Sidebar
                    VStack(alignment: .leading, spacing: 6) {
                        // App Brand Title
                        HStack(spacing: 8) {
                            Image(systemName: appState.appLogoStyle.iconName)
                                .font(.system(size: 20))
                                .foregroundColor(GlassTheme.cyanNeon)
                            Text("NetBoost")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 10)

                        // Navigation Items
                        ForEach(AppNavigationTab.allCases) { tab in
                            sidebarItem(tab: tab)
                        }

                        Spacer()

                        // Footer Status Info
                        VStack(alignment: .leading, spacing: 3) {
                            Text("macOS Sonoma / Sequoia")
                                .font(.system(size: 9))
                                .foregroundColor(GlassTheme.textTertiary)
                            Text("v1.0.0 · M6 Liquid Glass")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(GlassTheme.textTertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                    .frame(width: 200)
                    .background(GlassTheme.backgroundDark.opacity(0.3))
                    .overlay(
                        Rectangle()
                            .frame(width: 1)
                            .foregroundColor(Color.white.opacity(0.06)),
                        alignment: .trailing
                    )

                    // Active Tab View Content
                    Group {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: GlassTheme.minWindowWidth, minHeight: GlassTheme.minWindowHeight)
    }

    private func sidebarItem(tab: AppNavigationTab) -> some View {
        let isSelected = appState.selectedTab == tab

        return Button {
            appState.selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? accentForTab(tab) : GlassTheme.textSecondary)
                    .frame(width: 20)

                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .white : GlassTheme.textSecondary)

                Spacer()

                if isSelected {
                    Circle()
                        .fill(accentForTab(tab))
                        .frame(width: 5, height: 5)
                        .shadow(color: accentForTab(tab), radius: 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Group {
                    if isSelected {
                        accentForTab(tab).opacity(0.15)
                    } else {
                        Color.clear
                    }
                }
            )
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? accentForTab(tab).opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private func accentForTab(_ tab: AppNavigationTab) -> Color {
        switch tab {
        case .dashboard: return GlassTheme.cyanNeon
        case .hotspot: return GlassTheme.emeraldGreen
        case .dispatcher: return GlassTheme.cyanSapphire
        case .vpn: return GlassTheme.amberWarning
        case .accelerator: return GlassTheme.violetAccent
        case .doctor: return GlassTheme.emeraldHotspot
        case .aiDoctor: return GlassTheme.violetChunks
        }
    }
}
