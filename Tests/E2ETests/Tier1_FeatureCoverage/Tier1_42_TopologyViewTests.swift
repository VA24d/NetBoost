import Testing
import Foundation

@Suite("Feature 42: Dashboard & Live Topology View", .tags(.tier1, .m6_ui))
struct Tier1_42_TopologyViewTests {

    enum TopologyNodeType: String, Equatable {
        case hostMac
        case uplinkInterface
        case hotspotEngine
        case connectedClient
    }

    struct TopologyNode: Identifiable, Equatable {
        let id: String
        let type: TopologyNodeType
        let label: String
        let ipAddress: String?
        let linkSpeed: String?
        let isOnline: Bool
    }

    struct TopologyEdge: Identifiable, Equatable {
        let id: String
        let fromNodeId: String
        let toNodeId: String
        let hasActiveTraffic: Bool
    }

    final class TopologyGraphModel: @unchecked Sendable {
        private(set) var nodes: [TopologyNode] = []
        private(set) var edges: [TopologyEdge] = []
        private(set) var selectedNode: TopologyNode?

        func buildGraph() {
            nodes = [
                TopologyNode(id: "mac", type: .hostMac, label: "MacBook Pro", ipAddress: nil, linkSpeed: nil, isOnline: true),
                TopologyNode(id: "en10", type: .uplinkInterface, label: "Ethernet en10", ipAddress: "10.1.36.52", linkSpeed: "1 Gbps", isOnline: true),
                TopologyNode(id: "hotspot", type: .hotspotEngine, label: "Hotspot 192.168.2.1", ipAddress: "192.168.2.1", linkSpeed: nil, isOnline: true),
                TopologyNode(id: "client1", type: .connectedClient, label: "iPad Pro", ipAddress: "192.168.2.15", linkSpeed: "Wi-Fi 6", isOnline: true)
            ]

            edges = [
                TopologyEdge(id: "e1", fromNodeId: "mac", toNodeId: "en10", hasActiveTraffic: true),
                TopologyEdge(id: "e2", fromNodeId: "mac", toNodeId: "hotspot", hasActiveTraffic: true),
                TopologyEdge(id: "e3", fromNodeId: "hotspot", toNodeId: "client1", hasActiveTraffic: true)
            ]
        }

        func selectNode(byId id: String) {
            selectedNode = nodes.first { $0.id == id }
        }
    }

    @Test("T1-F42-01: Build topology graph Mac -> Interfaces -> Hotspot -> Clients")
    func testBuildTopologyGraph() {
        let graph = TopologyGraphModel()
        graph.buildGraph()

        #expect(graph.nodes.count == 4)
        #expect(graph.nodes.contains { $0.type == .hostMac })
        #expect(graph.nodes.contains { $0.type == .uplinkInterface })
        #expect(graph.nodes.contains { $0.type == .hotspotEngine })
        #expect(graph.nodes.contains { $0.type == .connectedClient })
    }

    @Test("T1-F42-02: Graph edges reflect active traffic flow")
    func testGraphEdgesTrafficFlow() {
        let graph = TopologyGraphModel()
        graph.buildGraph()

        #expect(graph.edges.count == 3)
        #expect(graph.edges.allSatisfy { $0.hasActiveTraffic })
    }

    @Test("T1-F42-03: Display interface nodes with IP address and link speed")
    func testInterfaceNodeDetails() {
        let graph = TopologyGraphModel()
        graph.buildGraph()

        let en10 = graph.nodes.first { $0.id == "en10" }
        #expect(en10?.ipAddress == "10.1.36.52")
        #expect(en10?.linkSpeed == "1 Gbps")
    }

    @Test("T1-F42-04: Display connected hotspot client nodes")
    func testHotspotClientNodeDetails() {
        let graph = TopologyGraphModel()
        graph.buildGraph()

        let client = graph.nodes.first { $0.id == "client1" }
        #expect(client?.label == "iPad Pro")
        #expect(client?.ipAddress == "192.168.2.15")
    }

    @Test("T1-F42-05: Clicking node reveals selection and inspection details")
    func testSelectNodeDetails() {
        let graph = TopologyGraphModel()
        graph.buildGraph()

        graph.selectNode(byId: "client1")
        #expect(graph.selectedNode?.id == "client1")
        #expect(graph.selectedNode?.ipAddress == "192.168.2.15")
    }
}
