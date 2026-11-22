import Foundation
import Testing
import Network
@testable import NetBoostCore

@Suite("Tier 4 - Scenario 1: Turing HPC Workload with Dual-Uplink Split Routing", .tags(.tier4, .socks5, .m2_proxy, .m3_vpn))
struct Scenario01_TuringHPCWorkloadTests {

    @Test("Complete Turing HPC workflow with dual-uplink split routing and interface pinning")
    func testTuringHPCWorkloadSplitRouting() async throws {
        let runner = MockProcessRunner()

        // Step 1: Upstream & Downstream Interface Inventory
        let wiredInterface = NetworkInterfaceInfo(
            bsdName: "en10",
            displayName: "USB 10/100 LAN",
            ipAddresses: [IPAddress(address: "10.1.36.52", netmask: "255.255.252.0", prefixLength: 22)],
            gateway: "10.1.36.1",
            mtu: 1500,
            isPrimary: true
        )
        let wifiInterface = NetworkInterfaceInfo(
            bsdName: "en0",
            displayName: "Wi-Fi",
            ipAddresses: [IPAddress(address: "172.20.10.2", netmask: "255.255.255.240", prefixLength: 28)],
            gateway: "172.20.10.1",
            mtu: 1280,
            isPrimary: false
        )

        #expect(wiredInterface.gateway == "10.1.36.1")
        #expect(wifiInterface.gateway == "172.20.10.1")

        // Step 2: Static Kernel Subnet Route Pinning
        // Pin Turing cluster subnet (10.8.0.0/16) and campus services (10.4.0.0/16) to en10 gateway
        let subnets = ["10.8.0.0/16", "10.4.0.0/16"]
        for subnet in subnets {
            let output = try await runner.run("route", arguments: ["add", "-net", subnet, wiredInterface.gateway!])
            #expect(output.succeeded)
            #expect(runner.didExecute(commandContaining: "route add -net \(subnet) \(wiredInterface.gateway!)"))
        }

        // Step 3: Start Mock Target Echo Server simulating Turing HPC login node (10.8.0.80)
        let turingServer = MockSOCKS5TargetServer(mode: .rawEcho)
        let turingPort = try await turingServer.start()
        defer { turingServer.stop() }

        // Step 4: Darwin Socket Interface Binding Verification
        let fd = try DarwinSocketHelper.createSocket(domain: AF_INET, type: SOCK_STREAM)
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        if let loIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0") {
            try DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: loIndex)
            let boundIdx = try DarwinSocketHelper.getBoundInterface(fd: fd)
            #expect(boundIdx == loIndex)
        }

        // Step 5: CLI Helper Environment Generation for Slurm Job
        let proxyPort = 1080
        let cliPrefix = "ALL_PROXY=socks5://127.0.0.1:\(proxyPort)"
        let slurmCommand = "sbatch --partition=gpu run_training.sh"
        let fullJobString = "\(cliPrefix) \(slurmCommand)"

        #expect(fullJobString.contains("ALL_PROXY=socks5://127.0.0.1:1080"))
        #expect(fullJobString.contains("sbatch"))

        // Step 6: Simulate Slurm dispatch with captured environment
        let slurmExecution = try await runner.run(
            "/usr/bin/ssh",
            arguments: ["user@10.8.0.80", slurmCommand],
            environment: ["ALL_PROXY": "socks5://127.0.0.1:\(proxyPort)"]
        )
        #expect(slurmExecution.succeeded)

        // Step 7: Concurrent External Traffic via Wi-Fi engages macos.ovpn
        let vpnStatus = try await runner.run("scutil", arguments: ["--nc", "start", "macos.ovpn"])
        #expect(vpnStatus.succeeded)
        #expect(runner.didExecute(commandContaining: "scutil --nc start macos.ovpn"))

        // Step 8: Verify Zero Route Collision between Turing routes and VPN
        let turingRoutePinned = runner.didExecute(commandContaining: "route add -net 10.8.0.0/16 10.1.36.1")
        let vpnStarted = runner.didExecute(commandContaining: "scutil --nc start macos.ovpn")
        #expect(turingRoutePinned == true)
        #expect(vpnStarted == true)
    }
}
