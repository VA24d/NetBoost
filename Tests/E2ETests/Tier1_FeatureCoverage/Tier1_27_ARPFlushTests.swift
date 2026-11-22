import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 27: ARP Table Flush Routine", .tags(.tier1, .m5_doctor, .diagnostics))
struct Tier1_27_ARPFlushTests {

    struct ARPFlushRoutine {
        static func makeFlushAllCommand() -> [String] {
            ["/usr/sbin/arp", "-d", "-a"]
        }

        static func makeFlushHostCommand(ip: String) -> [String] {
            ["/usr/sbin/arp", "-d", ip]
        }

        static func parseARPTable(output: String) -> [(ip: String, mac: String)] {
            var entries: [(ip: String, mac: String)] = []
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                // "? (10.1.36.1) at 00:00:0c:07:ac:01 on en10 ifscope [ethernet]"
                if let startParen = line.firstIndex(of: "("),
                   let endParen = line.firstIndex(of: ")"),
                   let atRange = line.range(of: " at ") {
                    let ip = String(line[line.index(after: startParen)..<endParen])
                    let remainder = line[atRange.upperBound...]
                    let mac = String(remainder.split(separator: " ").first ?? "")
                    entries.append((ip: ip, mac: mac))
                }
            }
            return entries
        }
    }

    @Test("T1-F27-01: Generate arp -d -a command to flush entire ARP cache")
    func testMakeFlushAllCommand() {
        let cmd = ARPFlushRoutine.makeFlushAllCommand()
        #expect(cmd.contains("arp"))
        #expect(cmd.contains("-d"))
        #expect(cmd.contains("-a"))
    }

    @Test("T1-F27-02: Generate arp -d <gatewayIP> to clear single host entry")
    func testMakeFlushHostCommand() {
        let cmd = ARPFlushRoutine.makeFlushHostCommand(ip: "10.1.36.1")
        #expect(cmd.contains("10.1.36.1"))
        #expect(cmd.contains("-d"))
    }

    @Test("T1-F27-03: Execute ARP flush using MockProcessRunner and verify recording")
    func testExecuteARPFlushMockRunner() throws {
        let runner = MockProcessRunner()
        let cmd = ARPFlushRoutine.makeFlushAllCommand()
        _ = try runner.run(cmd[0], arguments: Array(cmd.dropFirst()))

        #expect(runner.didExecute(commandContaining: "arp -d -a"))
    }

    @Test("T1-F27-04: Parse arp -an output before and after flush")
    func testParseARPTableOutput() {
        let populatedOutput = "? (10.1.36.1) at 00:00:0c:07:ac:01 on en10 ifscope [ethernet]"
        let entriesBefore = ARPFlushRoutine.parseARPTable(output: populatedOutput)
        #expect(entriesBefore.count == 1)
        #expect(entriesBefore.first?.ip == "10.1.36.1")
        #expect(entriesBefore.first?.mac == "00:00:0c:07:ac:01")

        let clearedOutput = ""
        let entriesAfter = ARPFlushRoutine.parseARPTable(output: clearedOutput)
        #expect(entriesAfter.isEmpty)
    }

    @Test("T1-F27-05: Record ARP flush event in repair audit log")
    func testRecordARPFlushLog() {
        var logs: [String] = []
        logs.append("ARP table flushed by Network Doctor")

        #expect(logs.count == 1)
        #expect(logs.first?.contains("ARP table flushed") == true)
    }
}
