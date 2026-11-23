import Testing
import Foundation
@testable import NetBoostCore

@Suite("Campus Diagnostics: RepairRoutines Unit & Integration Tests")
struct RepairRoutinesTests {

    @Test("DNS flush commands contain dscacheutil and killall mDNSResponder")
    func testDNSFlushCommandStructure() {
        let (cmd1, cmd2) = DNSFlushRoutine.makeCommands()
        #expect(cmd1 == ["/usr/bin/dscacheutil", "-flushcache"])
        #expect(cmd2 == ["/usr/bin/killall", "-HUP", "mDNSResponder"])
    }

    @Test("ARP flush commands support both full cache flush and single IP target")
    func testARPFlushCommands() {
        let allCmd = ARPFlushRoutine.makeFlushAllCommand()
        #expect(allCmd == ["/usr/sbin/arp", "-d", "-a"])

        let hostCmd = ARPFlushRoutine.makeFlushHostCommand(ip: "10.1.36.1")
        #expect(hostCmd == ["/usr/sbin/arp", "-d", "10.1.36.1"])
    }

    @Test("Parse ARP output accurately extracting IP and MAC address pairs")
    func testParseARPOutput() {
        let mockOutput = """
        ? (10.1.36.1) at 00:00:0c:07:ac:01 on en10 ifscope [ethernet]
        ? (10.1.36.52) at 00:11:22:33:44:55 on en10 ifscope [ethernet]
        """

        let entries = ARPFlushRoutine.parseARPTable(output: mockOutput)
        #expect(entries.count == 2)
        #expect(entries[0].ip == "10.1.36.1")
        #expect(entries[0].mac == "00:00:0c:07:ac:01")
        #expect(entries[1].ip == "10.1.36.52")
        #expect(entries[1].mac == "00:11:22:33:44:55")
    }

    @Test("DNS override manager generates Empty and campus resolver commands")
    func testDNSOverrideManagerCommands() {
        let resetCmd = DNSOverrideManager.makeResetDNSCommand(service: "Wi-Fi")
        #expect(resetCmd == ["/usr/sbin/networksetup", "-setdnsservers", "Wi-Fi", "Empty"])

        let campusCmd = DNSOverrideManager.makeSetCampusDNSCommand(service: "USB 10/100 LAN")
        #expect(campusCmd == ["/usr/sbin/networksetup", "-setdnsservers", "USB 10/100 LAN", "10.4.20.21", "10.4.20.222"])

        let servers = DNSOverrideManager.parseGetDNSServersOutput("10.4.20.21\n10.4.20.222\n")
        #expect(servers == ["10.4.20.21", "10.4.20.222"])

        let emptyServers = DNSOverrideManager.parseGetDNSServersOutput("There aren't any DNS Servers set on Wi-Fi.")
        #expect(emptyServers.isEmpty)
    }

    @Test("IPv6 manager generates disable and automatic commands and parses state")
    func testIPv6ManagerCommands() {
        let disableCmd = IPv6Manager.makeDisableIPv6Command(service: "USB 10/100 LAN")
        #expect(disableCmd == ["/usr/sbin/networksetup", "-setv6off", "USB 10/100 LAN"])

        let autoCmd = IPv6Manager.makeEnableIPv6AutomaticCommand(service: "USB 10/100 LAN")
        #expect(autoCmd == ["/usr/sbin/networksetup", "-setv6automatic", "USB 10/100 LAN"])

        let mockGetInfo = "IP address: 10.1.36.52\nIPv6: Off\n"
        #expect(IPv6Manager.parseIPv6State(fromGetInfo: mockGetInfo) == "Off")
    }

    @Test("Proxy settings manager generates commands to disable auto and manual web proxies")
    func testProxySettingsManager() {
        let autoCmd = ProxySettingsManager.makeDisableAutoProxyCommand(service: "Wi-Fi")
        #expect(autoCmd == ["/usr/sbin/networksetup", "-setautoproxystate", "Wi-Fi", "off"])

        let webCmd = ProxySettingsManager.makeDisableWebProxyCommand(service: "Wi-Fi")
        #expect(webCmd == ["/usr/sbin/networksetup", "-setwebproxystate", "Wi-Fi", "off"])

        let secWebCmd = ProxySettingsManager.makeDisableSecureWebProxyCommand(service: "Wi-Fi")
        #expect(secWebCmd == ["/usr/sbin/networksetup", "-setsecurewebproxystate", "Wi-Fi", "off"])

        #expect(ProxySettingsManager.parseProxyState(output: "Enabled: Yes") == true)
        #expect(ProxySettingsManager.parseProxyState(output: "Enabled: No") == false)
    }

    @Test("Audit log tracks repair actions sequentially with timestamps")
    func testAuditLogTracking() {
        let routines = RepairRoutines()
        #expect(routines.history.isEmpty)

        routines.recordEvent("DNS cache flushed")
        routines.recordEvent("ARP table flushed")

        #expect(routines.history.count == 2)
        #expect(routines.history[0].contains("DNS cache flushed"))
        #expect(routines.history[1].contains("ARP table flushed"))
    }
}
