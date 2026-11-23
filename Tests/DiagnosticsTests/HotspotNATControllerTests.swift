import Testing
import Foundation
@testable import NetBoostCore

@Suite("Hotspot Sharing: HotspotNATController Unit & Integration Tests")
struct HotspotNATControllerTests {

    @Test("SysctlForwardingController commands and state parsing")
    func testSysctlForwardingController() {
        let queryCmd = SysctlForwardingController.makeQueryCommand()
        #expect(queryCmd == ["/usr/sbin/sysctl", "-n", "net.inet.ip.forwarding"])

        let enableCmd = SysctlForwardingController.makeEnableCommand()
        #expect(enableCmd == ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1"])

        let disableCmd = SysctlForwardingController.makeDisableCommand()
        #expect(disableCmd == ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0"])

        #expect(SysctlForwardingController.parseForwardingState(output: "1\n") == true)
        #expect(SysctlForwardingController.parseForwardingState(output: "1") == true)
        #expect(SysctlForwardingController.parseForwardingState(output: "0\n") == false)
        #expect(SysctlForwardingController.parseForwardingState(output: "0") == false)
    }

    @Test("PFNATAnchorManager generates exact isolated NAT anchor rules")
    func testPFNATAnchorRules() {
        let manager = PFNATAnchorManager(
            anchorName: "netboost",
            upstreamInterface: "en10",
            clientSubnet: "192.168.2.0/24"
        )

        let rule = manager.generateNATRule()
        #expect(rule.contains("nat on en10 from 192.168.2.0/24 to any -> (en10)"))
        #expect(rule.contains("pass out quick on en10 from 192.168.2.0/24 to any keep state"))

        let loadCmd = manager.makeLoadAnchorCommand(ruleFile: "/tmp/test.pf")
        #expect(loadCmd == ["/sbin/pfctl", "-a", "netboost", "-f", "/tmp/test.pf"])

        let enableCmd = manager.makeEnablePFCommand()
        #expect(enableCmd == ["/sbin/pfctl", "-e"])

        let flushCmd = manager.makeFlushAnchorCommand()
        #expect(flushCmd == ["/sbin/pfctl", "-a", "netboost", "-F", "all"])
    }

    @Test("HotspotNATController initial state and configuration defaults")
    func testHotspotInitialState() {
        let controller = HotspotNATController()
        #expect(controller.isActive == false)
        #expect(controller.configuration.subnet == "192.168.2.0/24")
        #expect(controller.configuration.gateway == "192.168.2.1")
        #expect(controller.configuration.upstreamInterface == "en10")
        #expect(controller.configuration.interfaceName == "en0")
    }
}
