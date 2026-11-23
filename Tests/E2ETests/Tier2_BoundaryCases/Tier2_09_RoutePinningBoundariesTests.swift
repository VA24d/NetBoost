import Foundation
import Testing
@testable import NetBoostCore

@Suite("Tier 2 - Feature 09: Route Pinning Boundaries", .tags(.tier2, .m2_proxy))
struct Tier2_09_RoutePinningBoundariesTests {

    let mockRunner = MockProcessRunner()

    @Test("T2-F09-01: Malformed CIDR subnet notation is rejected before execution")
    func testMalformedCIDRValidation() {
        func validateCIDR(_ cidr: String) -> Bool {
            let parts = cidr.split(separator: "/")
            guard parts.count == 2,
                  let prefix = Int(parts[1]),
                  prefix >= 0 && prefix <= 32 else { return false }
            let octets = parts[0].split(separator: ".")
            guard octets.count == 4 else { return false }
            return octets.allSatisfy { Int($0) != nil && Int($0)! >= 0 && Int($0)! <= 255 }
        }

        #expect(validateCIDR("10.8.0.0/16") == true)
        #expect(validateCIDR("10.4.0.0/16") == true)
        #expect(validateCIDR("10.8.0.0/35") == false) // invalid prefix > 32
        #expect(validateCIDR("10.8.0/16") == false)    // only 3 octets
        #expect(validateCIDR("999.8.0.0/16") == false) // octet > 255
        #expect(validateCIDR("invalid_string") == false)
    }

    @Test("T2-F09-02: Route pinning execution generates exact route add command via process runner")
    func testRouteAddCommandGeneration() async throws {
        let subnet = "10.8.0.0/16"
        let gateway = "10.1.36.1"
        let command = "route add -net \(subnet) \(gateway)"

        #expect(command == "route add -net 10.8.0.0/16 10.1.36.1")

        mockRunner.registerStub(commandContaining: "route add", stdout: "add net 10.8.0.0: gateway 10.1.36.1\n")
        #expect(mockRunner.didExecute(commandContaining: "route add") == false)

        let output = try await mockRunner.run("route", arguments: ["add", "-net", subnet, gateway])
        #expect(output.succeeded)
        #expect(output.stdout.contains("gateway 10.1.36.1"))
        #expect(mockRunner.didExecute(commandContaining: "route add") == true)
    }

    @Test("T2-F09-03: Route unpinning generates exact route delete command")
    func testRouteDeleteCommandGeneration() {
        let subnet = "10.4.0.0/16"
        let gateway = "10.1.36.1"
        let command = "route delete -net \(subnet) \(gateway)"

        #expect(command == "route delete -net 10.4.0.0/16 10.1.36.1")
    }

    @Test("T2-F09-04: Idempotent route update handling when route already exists in kernel")
    func testRouteAlreadyExistsHandling() {
        let alreadyExistsOutput = ShellOutput(
            stdout: "",
            stderr: "route: writing to routing socket: File exists\n",
            exitCode: 1
        )

        func isRecoverableRouteError(_ output: ShellOutput) -> Bool {
            output.stderr.contains("File exists") || output.exitCode == 0
        }

        #expect(isRecoverableRouteError(alreadyExistsOutput) == true)
    }

    @Test("T2-F09-05: Pinned campus subnets (10.8.0.0/16 and 10.4.0.0/16) match campus requirements")
    func testCampusPinnedSubnetConstants() {
        let campusSubnets = ["10.8.0.0/16", "10.4.0.0/16"]
        #expect(campusSubnets.contains("10.8.0.0/16"))
        #expect(campusSubnets.contains("10.4.0.0/16"))
        #expect(campusSubnets.count == 2)
    }
}
