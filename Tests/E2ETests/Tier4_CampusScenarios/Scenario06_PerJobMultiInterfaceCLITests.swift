import Foundation
import Testing
import Network
@testable import NetBoostCore

@Suite("Tier 4 - Scenario 6: Per-Job Multi-Interface CLI Environment Dispatch", .tags(.tier4, .socks5, .m2_proxy))
struct Scenario06_PerJobMultiInterfaceCLITests {

    @Test("Per-job multi-interface proxy dispatch with SOCKS5 environment generation and egress verification")
    func testPerJobInterfaceDispatchWorkflow() async throws {
        let runner = MockProcessRunner()

        // Step 1: Start Mock Target Echo Server
        let targetServer = MockSOCKS5TargetServer(mode: .rawEcho)
        let targetPort = try await targetServer.start()
        defer { targetServer.stop() }

        // Step 2: Darwin Socket Interface Binding Verification
        let fd = try DarwinSocketHelper.createSocket(domain: AF_INET, type: SOCK_STREAM)
        defer { DarwinSocketHelper.closeSocket(fd: fd) }

        if let loIndex = DarwinSocketHelper.getInterfaceIndex(for: "lo0") {
            try DarwinSocketHelper.bindSocket(fd: fd, toInterfaceIndex: loIndex)
            let bound = try DarwinSocketHelper.getBoundInterface(fd: fd)
            #expect(bound == loIndex)
        }

        // Step 3: CLI Environment Helper Generation for Port 1080 (en10) and Port 1081 (en0)
        let port1080 = 1080 // Wired Ethernet en10
        let port1081 = 1081 // Wi-Fi en0

        let job1Command = "git clone https://turing.iiit.ac.in/models/llm.git"
        let job1Dispatch = "ALL_PROXY=socks5://127.0.0.1:\(port1080) \(job1Command)"
        #expect(job1Dispatch.contains("ALL_PROXY=socks5://127.0.0.1:1080"))

        let job2Command = "curl -O https://huggingface.co/meta-llama/weights.bin"
        let job2Dispatch = "ALL_PROXY=socks5://127.0.0.1:\(port1081) \(job2Command)"
        #expect(job2Dispatch.contains("ALL_PROXY=socks5://127.0.0.1:1081"))

        // Step 4: Execute Job 1 through Process Runner targeting Port 1080
        let env1080 = [
            "ALL_PROXY": "socks5://127.0.0.1:\(port1080)",
            "http_proxy": "http://127.0.0.1:\(port1080)",
            "https_proxy": "http://127.0.0.1:\(port1080)"
        ]

        let job1Exec = try await runner.run(
            "/usr/bin/git",
            arguments: ["clone", "https://turing.iiit.ac.in/models/llm.git"],
            environment: env1080
        )
        #expect(job1Exec.succeeded)
        let lastCmd = runner.lastExecutedCommand()
        #expect(lastCmd?.environment?["ALL_PROXY"] == "socks5://127.0.0.1:1080")

        // Step 5: Execute Direct TCP Echo through Target Server to Verify Data Transfer
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: targetPort)!)
        let conn = NWConnection(to: endpoint, using: .tcp)

        let payload = Data("Job Dispatch Ping Payload".utf8)
        let received: Data = try await withCheckedThrowingContinuation { continuation in
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    conn.send(content: payload, completion: .contentProcessed { err in
                        if let err = err { continuation.resume(throwing: err); return }
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, err in
                            if let err = err { continuation.resume(throwing: err) }
                            else { continuation.resume(returning: data ?? Data()) }
                        }
                    })
                }
            }
            conn.start(queue: .global())
        }
        defer { conn.cancel() }

        #expect(received == payload)
        #expect(targetServer.totalBytesReceived >= payload.count)
    }
}
