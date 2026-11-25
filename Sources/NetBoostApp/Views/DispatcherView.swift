import AppKit
import SwiftUI
import NetBoostCore

public struct DispatcherView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isTogglingProxy = false
    @State private var commandInput = ""
    @State private var selectedLaunchPort = 1080
    @State private var customCIDR = ""
    @State private var customGateway = ""
    @State private var isPinningRoute = false
    @State private var isRefreshingRoutes = false

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                headerRow

                if let err = appState.proxyError, !err.isEmpty {
                    errorBanner(err)
                }

                proxyEngineCard
                commandLauncherCard
                routePinningCard
                activeConnectionsCard
            }
            .padding(20)
        }
        .task {
            if appState.pinnedRoutes.isEmpty {
                await appState.refreshPinnedRoutes()
            }
            appState.refreshProxyMetrics()
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            PageHeader(
                title: "Proxy Dispatcher",
                subtitle: "Route traffic per process over local SOCKS5/HTTP listeners with kernel route pinning"
            )
            Spacer(minLength: 12)
            StatusPill(
                text: appState.isProxyActive ? "Active" : "Off",
                color: appState.isProxyActive ? GlassTheme.cyanSapphire : GlassTheme.textTertiary,
                showPulse: appState.isProxyActive
            )
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(GlassTheme.redAlert)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(GlassTheme.textPrimary)
            Spacer()
        }
        .padding(12)
        .background(GlassTheme.redAlert.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(GlassTheme.redAlert.opacity(0.35), lineWidth: 0.75)
        )
    }

    // MARK: - Proxy Engine & Listeners

    private var proxyEngineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local proxy listeners")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(GlassTheme.textPrimary)
                    Text("Binds 127.0.0.1 ports across Ethernet, Wi-Fi, and load-balanced egress")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.textSecondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 14) {
                    throughputCounter(
                        label: "Received",
                        value: SpeedFormatter.formatBytes(appState.proxyTotalBytesRead),
                        color: GlassTheme.cyanSapphire
                    )
                    throughputCounter(
                        label: "Sent",
                        value: SpeedFormatter.formatBytes(appState.proxyTotalBytesWritten),
                        color: GlassTheme.emeraldGreen
                    )
                }
                .layoutPriority(1)

                Toggle("Enable proxy dispatcher", isOn: Binding(
                    get: { appState.isProxyActive },
                    set: { _ in
                        Task {
                            isTogglingProxy = true
                            defer { isTogglingProxy = false }
                            do {
                                try await appState.toggleProxy()
                            } catch {
                                appState.proxyError = error.localizedDescription
                            }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(isTogglingProxy)
            }

            Rectangle()
                .fill(GlassTheme.separator.opacity(0.6))
                .frame(height: 1)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                spacing: 12
            ) {
                portListenerTile(
                    port: 1080,
                    title: "Ethernet",
                    interfaceName: appState.proxyPorts[1080] ?? "en10",
                    description: "Wired campus uplink",
                    accentColor: GlassTheme.sapphireBlue
                )

                portListenerTile(
                    port: 1081,
                    title: "Wi-Fi",
                    interfaceName: appState.proxyPorts[1081] ?? "en0",
                    description: "Wireless or cellular uplink",
                    accentColor: GlassTheme.emeraldGreen
                )

                portListenerTile(
                    port: 1082,
                    title: "Balanced",
                    interfaceName: appState.proxyPorts[1082] ?? "auto",
                    description: "Round-robin multi-uplink",
                    accentColor: GlassTheme.violetAccent
                )
            }

            if let copied = appState.copiedSnippetMessage, !copied.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(GlassTheme.emeraldGreen)
                    Text(copied)
                        .font(.system(size: 11.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.textSecondary)
                }
            }
        }
        .padding(16)
        .glassCard(
            cornerRadius: 12,
            strokeColor: appState.isProxyActive ? GlassTheme.cyanSapphire.opacity(0.45) : Color.white.opacity(0.10)
        )
    }

    private func throughputCounter(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(GlassTheme.textTertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(color)
        }
    }

    private func portListenerTile(
        port: Int,
        title: String,
        interfaceName: String,
        description: String,
        accentColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(port)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(GlassTheme.textPrimary)
                Spacer(minLength: 4)
                StatusPill(
                    text: interfaceName,
                    color: appState.isProxyActive ? accentColor : GlassTheme.textTertiary,
                    showPulse: appState.isProxyActive
                )
            }

            Text(description)
                .font(.system(size: 11.5))
                .foregroundColor(GlassTheme.textSecondary)
                .lineLimit(1)

            Button {
                _ = appState.generateShellSnippet(port: port)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                    Text("Copy export")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlowingButtonStyle(accentColor: accentColor))
        }
        .padding(12)
        .background(GlassTheme.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accentColor.opacity(appState.isProxyActive ? 0.35 : 0.16), lineWidth: 0.75)
        )
    }

    // MARK: - Quick Command Launcher

    private var commandLauncherCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Quick command launcher")
                Spacer()
                Text("Exports ALL_PROXY, HTTP_PROXY, HTTPS_PROXY on 127.0.0.1:\(selectedLaunchPort)")
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textTertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                TextField("Command (e.g. curl -sI https://turing.iiit.ac.in)", text: $commandInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
                    )
                    .onSubmit {
                        runLauncherCommand()
                    }

                Picker("Port", selection: $selectedLaunchPort) {
                    Text("1080 (Ethernet)").tag(1080)
                    Text("1081 (Wi-Fi)").tag(1081)
                    Text("1082 (Balanced)").tag(1082)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 148)

                Button {
                    runLauncherCommand()
                } label: {
                    HStack(spacing: 5) {
                        if appState.isRunningCLITask {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                        }
                        Text(appState.isRunningCLITask ? "Running" : "Run")
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire, isProminent: true))
                .disabled(commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isRunningCLITask)
            }

            ScrollView(.vertical, showsIndicators: true) {
                Text(appState.cliTaskOutput.isEmpty ? "Command output will appear here." : appState.cliTaskOutput)
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(appState.cliTaskOutput.isEmpty ? GlassTheme.textTertiary : GlassTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 100, maxHeight: 165)
            .background(Color.black.opacity(0.32))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
            )
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    private func runLauncherCommand() {
        let trimmed = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !appState.isRunningCLITask else { return }
        Task {
            await appState.launchCLITask(command: trimmed, port: selectedLaunchPort)
        }
    }

    // MARK: - Kernel Route Pinning

    private var routePinningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionLabel("Kernel route pinning")
                if !appState.pinnedRoutes.isEmpty {
                    Text("\(appState.pinnedRoutes.count)")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(GlassTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(GlassTheme.controlFill)
                        .clipShape(Capsule())
                }
                Spacer()
                Button {
                    Task {
                        isRefreshingRoutes = true
                        defer { isRefreshingRoutes = false }
                        await appState.refreshPinnedRoutes()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isRefreshingRoutes {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11.5))
                        }
                        Text("Refresh")
                    }
                }
                .buttonStyle(GlowingButtonStyle())
                .disabled(isRefreshingRoutes)
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        isPinningRoute = true
                        defer { isPinningRoute = false }
                        await appState.pinCampusDefaultSubnets()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                        Text("Pin Campus Subnets (10.8.0.0/16, 10.4.0.0/16)")
                            .monospacedDigit()
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.sapphireBlue, isProminent: true))
                .disabled(isPinningRoute)

                Spacer()
            }

            HStack(spacing: 10) {
                TextField("CIDR (e.g. 10.8.0.0/16)", text: $customCIDR)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
                    )

                TextField("Gateway (optional)", text: $customGateway)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: 200)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
                    )

                Button("Pin Route") {
                    let subnet = customCIDR.trimmingCharacters(in: .whitespacesAndNewlines)
                    let gatewayText = customGateway.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !subnet.isEmpty else { return }
                    Task {
                        isPinningRoute = true
                        defer { isPinningRoute = false }
                        await appState.pinSubnet(
                            subnet,
                            gateway: gatewayText.isEmpty ? nil : gatewayText,
                            interface: nil
                        )
                    }
                }
                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.cyanSapphire))
                .disabled(customCIDR.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPinningRoute)
            }

            if let message = appState.routePinResultMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundColor(GlassTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GlassTheme.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if appState.pinnedRoutes.isEmpty {
                Text("No kernel routes loaded. Click Refresh to read the active IPv4 routing table.")
                    .font(.system(size: 12))
                    .foregroundColor(GlassTheme.textSecondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("Subnet")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Gateway")
                                .frame(width: 130, alignment: .leading)
                            Text("Interface")
                                .frame(width: 80, alignment: .leading)
                            Text("Action")
                                .frame(width: 74, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(GlassTheme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)

                        ForEach(Array(appState.pinnedRoutes.enumerated()), id: \.offset) { _, route in
                            Rectangle()
                                .fill(GlassTheme.separator.opacity(0.45))
                                .frame(height: 1)

                            HStack(spacing: 12) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(route.isActive ? GlassTheme.emeraldGreen : GlassTheme.textTertiary)
                                        .frame(width: 6, height: 6)
                                    Text(route.subnet)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundColor(GlassTheme.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Text(route.gateway)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundColor(GlassTheme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: 130, alignment: .leading)

                                Text(route.interface)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundColor(GlassTheme.cyanSapphire)
                                    .lineLimit(1)
                                    .frame(width: 80, alignment: .leading)

                                Button("Unpin") {
                                    let validGateway = RoutePinningEngine.validateIPv4(route.gateway) ? route.gateway : nil
                                    Task {
                                        await appState.unpinSubnet(route.subnet, gateway: validGateway)
                                    }
                                }
                                .buttonStyle(GlowingButtonStyle(accentColor: GlassTheme.amberWarning))
                                .frame(width: 74, alignment: .trailing)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 210)
                .background(GlassTheme.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
                )
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Active Connections

    private var activeConnectionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionLabel("Active connections")
                Text("\(appState.activeConnections.count)")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(GlassTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(GlassTheme.controlFill)
                    .clipShape(Capsule())

                Spacer()

                Button {
                    appState.refreshProxyMetrics()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5))
                        Text("Refresh")
                    }
                }
                .buttonStyle(GlowingButtonStyle())
            }

            if appState.activeConnections.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 22))
                        .foregroundColor(GlassTheme.textTertiary)
                    Text(appState.isProxyActive
                         ? "No active connections routed through the dispatcher."
                         : "Enable the proxy dispatcher to inspect live connections.")
                        .font(.system(size: 12))
                        .foregroundColor(GlassTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Protocol")
                            .frame(width: 96, alignment: .leading)
                        Text("Destination")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Egress")
                            .frame(width: 78, alignment: .leading)
                        Text("Transferred")
                            .frame(width: 170, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(GlassTheme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)

                    ForEach(Array(appState.activeConnections.enumerated()), id: \.element.id) { index, conn in
                        if index > 0 {
                            Rectangle()
                                .fill(GlassTheme.separator.opacity(0.45))
                                .frame(height: 1)
                        }

                        HStack(spacing: 12) {
                            Text(protocolLabel(conn.protocolType))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(GlassTheme.cyanSapphire)
                                .frame(width: 96, alignment: .leading)

                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(conn.targetHost):\(conn.targetPort)")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundColor(GlassTheme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("Port \(conn.port) · \(conn.clientAddress)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundColor(GlassTheme.textTertiary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            StatusPill(
                                text: conn.egressInterface,
                                color: conn.egressInterface == "en10" ? GlassTheme.sapphireBlue : GlassTheme.emeraldGreen,
                                showPulse: false
                            )
                            .frame(width: 78, alignment: .leading)

                            Text("↓ \(SpeedFormatter.formatBytes(conn.bytesRead)) · ↑ \(SpeedFormatter.formatBytes(conn.bytesWritten))")
                                .font(.system(size: 11.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(GlassTheme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .frame(width: 170, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
                .background(GlassTheme.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(GlassTheme.controlBorder, lineWidth: 0.75)
                )
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 12)
    }

    // MARK: - Helpers

    private func protocolLabel(_ type: ProxyProtocolType) -> String {
        switch type {
        case .socks5: return "SOCKS5"
        case .httpConnect: return "HTTP CONNECT"
        case .httpDirect: return "HTTP"
        }
    }
}
