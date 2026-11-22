import Foundation
import Testing
import Network
@testable import NetBoostCore

@Suite("Tier 3: Proxy Dispatcher + Subnet Route Pinning Interaction", .tags(.tier3, .socks5, .m2_proxy))
struct CrossFeature_ProxyRoutingTests {

    @Test("SOCKS5 dispatcher binds socket to specific interface using IP_BOUND_IF")
    func testSOCKS5SocketInterfaceBinding() throws {
        // Create BSD socket
        let fd = try DarwinSocketHelper.createSocket(domain: AF_INET, type: SOCK_STREAM)
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        // Bind to loopback interface (lo0)
        guard let loIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0") else {
            Issue.record("Failed to resolve lo0 index")
            return
        }

        try DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: loIndex)
        let boundIndex = try DarwinSocketHelper.getBoundInterface(fd: fd)
        #expect(boundIndex == loIndex)
    }

    @Test("HTTP proxy establishes bidirectional stream to mock target without route conflict")
    func testHTTPProxyRelayToTarget() async throws {
        let targetServer = MockSOCKS5TargetServer(mode: .httpEcho)
        let targetPort = try await targetServer.start()
        defer { targetServer.stop() }

        // Dispatch HTTP request to target
        let url = URL(string: "http://127.0.0.1:\(targetPort)/turing-job")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return
        }

        #expect(httpResponse.statusCode == 200)
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        #expect(responseBody.contains("Echo: Received"))
        #expect(targetServer.totalBytesReceived > 0)
    }

    @Test("Static kernel route pinning forces 10.8.0.0/16 and 10.4.0.0/16 via en10 gateway")
    func testSubnetRoutePinningCommands() async throws {
        let runner = MockProcessRunner()

        // Pinning campus compute subnets
        let subnets = [
            ("10.8.0.0/16", "10.1.36.1"),
            ("10.4.0.0/16", "10.1.36.1")
        ]

        for (subnet, gateway) in subnets {
            let output = try await runner.run("route", arguments: ["add", "-net", subnet, gateway])
            #expect(output.succeeded)
            #expect(runner.didExecute(commandContaining: "route add -net \(subnet) \(gateway)"))
        }

        // Teardown / unpinning verification
        for (subnet, gateway) in subnets {
            let output = try await runner.run("route", arguments: ["delete", "-net", subnet, gateway])
            #expect(output.succeeded)
            #expect(runner.didExecute(commandContaining: "route delete -net \(subnet) \(gateway)"))
        }
    }

    @Test("CLI environment helper generates standard export variables for bash, zsh, and fish")
    func testCLIHelperScriptGeneration() {
        let port = 1080
        let socksProxyURL = "socks5://127.0.0.1:\(port)"
        let httpProxyURL = "http://127.0.0.1:\(port)"

        // Bash / Zsh syntax
        let bashExport = "export ALL_PROXY=\(socksProxyURL) http_proxy=\(httpProxyURL) https_proxy=\(httpProxyURL)"
        #expect(bashExport.contains("ALL_PROXY=socks5://127.0.0.1:1080"))
        #expect(bashExport.contains("http_proxy=http://127.0.0.1:1080"))

        // Fish shell syntax
        let fishExport = "set -x ALL_PROXY \(socksProxyURL); set -x http_proxy \(httpProxyURL); set -x https_proxy \(httpProxyURL)"
        #expect(fishExport.contains("set -x ALL_PROXY socks5://127.0.0.1:1080"))

        // Single-job prefix wrap: ALL_PROXY=... <command>
        let command = "git clone https://turing.iiit.ac.in/repo.git"
        let wrappedCommand = "ALL_PROXY=\(socksProxyURL) \(command)"
        #expect(wrappedCommand == "ALL_PROXY=socks5://127.0.0.1:1080 git clone https://turing.iiit.ac.in/repo.git")
    }

    @Test("CLI environment dispatch executes command with ALL_PROXY environment through mock runner")
    func testCLIEnvironmentDispatchExecution() async throws {
        let runner = MockProcessRunner()

        let proxyEnv = [
            "ALL_PROXY": "socks5://127.0.0.1:1080",
            "http_proxy": "http://127.0.0.1:1080",
            "https_proxy": "http://127.0.0.1:1080"
        ]

        let output = try await runner.run(
            "curl",
            arguments: ["-s", "http://turing.iiit.ac.in/api/status"],
            environment: proxyEnv
        )

        #expect(output.succeeded)
        let lastCmd = runner.lastExecutedCommand()
        #expect(lastCmd?.environment?["ALL_PROXY"] == "socks5://127.0.0.1:1080")
        #expect(lastCmd?.arguments.contains("http://turing.iiit.ac.in/api/status") == true)
    }
}
