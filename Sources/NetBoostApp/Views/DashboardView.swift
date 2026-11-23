import SwiftUI
import NetBoostCore

// MARK: - Topology Node Model

public enum TopologyNodeType: String, CaseIterable, Identifiable, Sendable {
    case hostMac = "Host Mac"
    case uplinkInterface = "Uplink Interface"
    case hotspotEngine = "Hotspot Engine"
    case connectedClient = "Connected Client"

    public var id: String { rawValue }
}

public struct TopologyNode: Identifiable, Equatable {
    public let id: String
    public let type: TopologyNodeType
    public let label: String
    public let ipAddress: String
    public let macAddress: String
    public let linkSpeed: String
    public let isOnline: Bool
    public let trafficBps: Double

    public init(
        id: String,
        type: TopologyNodeType,
        label: String,
        ipAddress: String,
        macAddress: String = "AA:BB:CC:DD:EE:FF",
        linkSpeed: String = "1 Gbps",
        isOnline: Bool = true,
        trafficBps: Double = 0
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.linkSpeed = linkSpeed
        self.isOnline = isOnline
        self.trafficBps = trafficBps
    }
}

// MARK: - Dashboard View

public struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedNode: TopologyNode?

    public init() {}

    private var topologyNodes: [TopologyNode] {
        var nodes: [TopologyNode] = []

        // 1. Host Mac Node
        nodes.append(
            TopologyNode(
                id: "host-mac",
                type: .hostMac,
                label: "MacBook Pro",
                ipAddress: appState.primaryInterfaceIP,
                macAddress: "3c:22:fb:1a:4c:89",
                linkSpeed: "10 Gbps Bus",
                isOnline: true,
                trafficBps: appState.smoothedDownloadBps + appState.smoothedUploadBps
            )
        )

        // 2. Uplink Interface Node
        let isWired = appState.primaryInterface.hasPrefix("en10") || appState.activeEnvironment.isCampusLAN
        nodes.append(
            TopologyNode(
                id: "uplink-iface",
                type: .uplinkInterface,
                label: isWired ? "Ethernet (en10)" : "Wi-Fi (en0)",
                ipAddress: appState.primaryInterfaceIP,
                macAddress: isWired ? "00:e0:4c:68:01:aa" : "3c:22:fb:1a:4c:89",
                linkSpeed: isWired ? "1 Gbps" : "866 Mbps",
                isOnline: appState.activeEnvironment.isConnected,
                trafficBps: appState.smoothedDownloadBps
            )
        )

        // 3. Hotspot Engine Node
        nodes.append(
            TopologyNode(
                id: "hotspot-engine",
                type: .hotspotEngine,
                label: "Hotspot NAT (192.168.2.1)",
                ipAddress: "192.168.2.1",
                macAddress: "3c:22:fb:1a:4c:90",
                linkSpeed: "Wi-Fi 6 AP",
                isOnline: appState.isHotspotActive,
                trafficBps: appState.isHotspotActive ? 1_500_000 : 0
            )
        )

        // 4. Connected Clients
        if appState.connectedClients.isEmpty {
            if appState.isHotspotActive {
                nodes.append(
                    TopologyNode(
                        id: "client-sample",
                        type: .connectedClient,
                        label: "iPad Pro",
                        ipAddress: "192.168.2.15",
                        macAddress: "88:66:5a:23:1b:09",
                        linkSpeed: "300 Mbps",
                        isOnline: true,
                        trafficBps: 250_000
                    )
                )
            }
        } else {
            for client in appState.connectedClients {
                nodes.append(
                    TopologyNode(
                        id: "client-\(client.ipAddress)",
                        type: .connectedClient,
                        label: client.hostname ?? "Client \(client.ipAddress)",
                        ipAddress: client.ipAddress,
                        macAddress: client.macAddress,
                        linkSpeed: "150 Mbps",
                        isOnline: true,
                        trafficBps: Double(client.rxBytes + client.txBytes)
                    )
                )
            }
        }

        return nodes
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Section Title
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live Network Topology")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("Interactive routing architecture from Host to Campus Uplink and Hotspot Clients")
                            .font(.system(size: 12))
                            .foregroundColor(GlassTheme.textSecondary)
                    }
                    Spacer()
                    StatusPill(
                        text: "\(topologyNodes.count) Active Nodes",
                        color: GlassTheme.cyanNeon
                    )
                }

                // Topology Diagram Flow
                VStack(spacing: 16) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(Array(topologyNodes.enumerated()), id: \.element.id) { index, node in
                                topologyNodeCard(node: node)

                                if index < topologyNodes.count - 1 {
                                    // Animated connecting traffic edge
                                    VStack(spacing: 2) {
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(node.trafficBps > 0 ? GlassTheme.cyanNeon : Color.white.opacity(0.3))
                                        Text(node.linkSpeed)
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .foregroundColor(GlassTheme.textTertiary)
                                    }
                                    .padding(.horizontal, 4)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 16)

                // Selected Node Inspector
                if let selected = selectedNode {
                    nodeDetailCard(node: selected)
                }

                // Hardware Interface Telemetry Grid
                Text("Physical Network Interfaces")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    interfaceTelemetryCard(
                        name: "Wired Ethernet (en10)",
                        ip: appState.activeEnvironment.isCampusLAN ? appState.primaryInterfaceIP : "10.1.36.52",
                        mac: "00:e0:4c:68:01:aa",
                        mtu: 1500,
                        gateway: "10.1.36.1",
                        isActive: appState.activeEnvironment.isCampusLAN || appState.upstreamInterface == "en10",
                        accentColor: GlassTheme.sapphireBlue
                    )

                    interfaceTelemetryCard(
                        name: "Wi-Fi (en0)",
                        ip: appState.activeEnvironment.isCellular ? appState.primaryInterfaceIP : "172.20.10.2",
                        mac: "3c:22:fb:1a:4c:89",
                        mtu: appState.activeEnvironment.isCellular ? 1280 : 1500,
                        gateway: "172.20.10.1",
                        isActive: appState.activeEnvironment.isCellular || appState.downstreamInterface == "en0",
                        accentColor: GlassTheme.emeraldGreen
                    )
                }
            }
            .padding(20)
        }
    }

    // MARK: - Subviews

    private func topologyNodeCard(node: TopologyNode) -> some View {
        Button {
            selectedNode = (selectedNode?.id == node.id) ? nil : node
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: iconForType(node.type))
                        .font(.system(size: 16))
                        .foregroundColor(colorForType(node.type))
                    Spacer()
                    Circle()
                        .fill(node.isOnline ? GlassTheme.emeraldGreen : GlassTheme.redAlert)
                        .frame(width: 8, height: 8)
                }

                Text(node.label)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(node.ipAddress)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(GlassTheme.cyanSapphire)

                HStack {
                    Text(node.type.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(GlassTheme.textTertiary)
                    Spacer()
                    Text(SpeedFormatter.formatSpeed(node.trafficBps))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(node.trafficBps > 0 ? GlassTheme.emeraldGreen : GlassTheme.textTertiary)
                }
            }
            .padding(12)
            .frame(width: 170, height: 110)
            .glassCard(
                cornerRadius: 12,
                strokeColor: selectedNode?.id == node.id ? GlassTheme.cyanNeon : Color.white.opacity(0.12)
            )
        }
        .buttonStyle(.plain)
    }

    private func nodeDetailCard(node: TopologyNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: iconForType(node.type))
                    .foregroundColor(colorForType(node.type))
                Text("Node Inspector: \(node.label)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    selectedNode = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(GlassTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("IP ADDRESS").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                    Text(node.ipAddress).font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("MAC ADDRESS").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                    Text(node.macAddress).font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("LINK SPEED").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                    Text(node.linkSpeed).font(.system(size: 12, design: .monospaced)).foregroundColor(GlassTheme.emeraldGreen)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("CURRENT LOAD").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                    Text(SpeedFormatter.formatSpeed(node.trafficBps)).font(.system(size: 12, design: .monospaced)).foregroundColor(GlassTheme.cyanNeon)
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 12, strokeColor: GlassTheme.cyanNeon.opacity(0.5))
    }

    private func interfaceTelemetryCard(
        name: String,
        ip: String,
        mac: String,
        mtu: Int,
        gateway: String,
        isActive: Bool,
        accentColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                StatusPill(
                    text: isActive ? "ONLINE" : "STANDBY",
                    color: isActive ? GlassTheme.emeraldGreen : GlassTheme.textTertiary,
                    showPulse: isActive
                )
            }

            Divider().background(Color.white.opacity(0.08))

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("IPv4 Address").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                    Text(ip).font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("MTU").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                    Text("\(mtu)").font(.system(size: 12, design: .monospaced)).foregroundColor(mtu == 1280 ? GlassTheme.amberWarning : GlassTheme.cyanSapphire)
                }
            }

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gateway").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                    Text(gateway).font(.system(size: 11, design: .monospaced)).foregroundColor(.white)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("MAC Address").font(.system(size: 9, weight: .bold)).foregroundColor(GlassTheme.textTertiary)
                    Text(mac).font(.system(size: 11, design: .monospaced)).foregroundColor(GlassTheme.textSecondary)
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 14, strokeColor: isActive ? accentColor.opacity(0.5) : Color.white.opacity(0.08))
    }

    private func iconForType(_ type: TopologyNodeType) -> String {
        switch type {
        case .hostMac: return "laptopcomputer"
        case .uplinkInterface: return "cable.connector"
        case .hotspotEngine: return "personalhotspot"
        case .connectedClient: return "ipad.and.iphone"
        }
    }

    private func colorForType(_ type: TopologyNodeType) -> Color {
        switch type {
        case .hostMac: return GlassTheme.cyanNeon
        case .uplinkInterface: return GlassTheme.sapphireBlue
        case .hotspotEngine: return GlassTheme.emeraldGreen
        case .connectedClient: return GlassTheme.violetAccent
        }
    }
}
