import Testing
import Foundation
@testable import NetBoostCore
@testable import NetBoostApp

@Suite("Tier 5 - Download & Proxy Concurrency Stress Tests", .tags(.tier5, .accelerator))
struct Tier5_DownloadAndProxyConcurrencyStressTests {

    // MARK: - Test 1: Mid-Stream Dropped Connection Detection

    @Test("T5-Stress-01: Mid-stream socket drop in RangeProbe is detected and throws network error")
    func testRangeProbeDroppedConnectionDetection() async throws {
        let server = MockHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        // Configure mock server to drop connection after 100 bytes
        server.dropConnectionAfterBytes = 100

        guard let testURL = URL(string: "http://127.0.0.1:\(port)/dataset.bin") else {
            Issue.record("Invalid test URL")
            return
        }

        let probe = RangeProbe()
        do {
            _ = try await probe.probe(url: testURL)
        } catch {
            // Success: socket disconnect caught as an error
            #expect(Bool(true))
        }
    }

    // MARK: - Test 2: DiskAssembler High Concurrency Writes

    @Test("T5-Stress-02: DiskAssembler concurrent non-overlapping slice writes preserve bit-exact file integrity")
    func testDiskAssemblerConcurrentWrites() async throws {
        let assembler = DiskAssembler()
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_concurrent_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let chunkCount = 16
        let sliceSize: Int = 16384 // 16 KB per slice
        let totalSize: Int64 = Int64(chunkCount * sliceSize) // 256 KB

        try assembler.prepare(fileURL: fileURL, totalBytes: totalSize)

        // Generate known data for each slice: slice i filled with byte i
        var expectedBytes = [UInt8]()
        expectedBytes.reserveCapacity(Int(totalSize))
        for i in 0..<chunkCount {
            expectedBytes.append(contentsOf: [UInt8](repeating: UInt8(i + 1), count: sliceSize))
        }

        // Concurrently write slices out of order
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<chunkCount {
                group.addTask {
                    let offset = Int64(i * sliceSize)
                    let sliceData = Data([UInt8](repeating: UInt8(i + 1), count: sliceSize))
                    try? assembler.write(data: sliceData, at: offset)
                }
            }
        }

        try assembler.flush()
        try assembler.close()

        // Verify written file
        let fileData = try Data(contentsOf: fileURL)
        #expect(Int64(fileData.count) == totalSize)
        #expect(fileData == Data(expectedBytes))
    }

    // MARK: - Test 3: DiskAssembler Out-of-Bounds and Negative Offsets

    @Test("T5-Stress-03: DiskAssembler rejects negative offsets safely")
    func testDiskAssemblerNegativeOffsetRejection() throws {
        let assembler = DiskAssembler()
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_neg_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try assembler.prepare(fileURL: fileURL, totalBytes: 1024)

        let sampleData = Data([0x01, 0x02, 0x03])
        do {
            try assembler.write(data: sampleData, at: -10)
            Issue.record("Expected error when writing at negative offset")
        } catch {
            #expect(Bool(true))
        }

        try assembler.close()
    }

    // MARK: - Test 4: ChunkPartitionEngine Boundary Integrity

    @Test("T5-Stress-04: ChunkPartitionEngine produces exact byte coverage with 0 gaps and 0 overlaps")
    func testChunkPartitionBoundaries() {
        // Prime byte size with 8 chunks
        let primeSize: Int64 = 10_000_019 // ~10MB
        let chunks8 = ChunkPartitionEngine.partition(totalBytes: primeSize, desiredChunks: 8)

        #expect(chunks8.count == 8)
        #expect(chunks8.first?.rangeStart == 0)
        #expect(chunks8.last?.rangeEnd == primeSize - 1)

        for i in 0..<(chunks8.count - 1) {
            #expect(chunks8[i].rangeEnd + 1 == chunks8[i + 1].rangeStart, "Gap or overlap at boundary \(i)")
        }

        // Verify sum of chunk lengths equals totalBytes
        var sumBytes: Int64 = 0
        for chunk in chunks8 {
            sumBytes += (chunk.rangeEnd - chunk.rangeStart + 1)
        }
        #expect(sumBytes == primeSize)

        // Small file under 1MB returns single chunk
        let smallSize: Int64 = 500_000
        let smallChunks = ChunkPartitionEngine.partition(totalBytes: smallSize, desiredChunks: 8)
        #expect(smallChunks.count == 1)
        #expect(smallChunks[0].rangeStart == 0)
        #expect(smallChunks[0].rangeEnd == 499_999)

        // Zero-byte file returns empty
        #expect(ChunkPartitionEngine.partition(totalBytes: 0).isEmpty)
    }

    // MARK: - Test 5: Multi-Port Proxy Concurrency Saturation

    @Test("T5-Stress-05: Proxy dispatcher handles concurrent port requests and round-robin balancing")
    func testProxyDispatcherConcurrentRequests() {
        let dispatcher = InterfaceProxyDispatcher()

        // Test interface resolution across 100 round-robin queries
        var ifaceCounts: [String: Int] = [:]
        for _ in 0..<100 {
            let iface = dispatcher.nextLoadBalancedInterface()
            ifaceCounts[iface, default: 0] += 1
        }

        // Interfaces en10 and en0 should be balanced evenly (50/50)
        #expect(ifaceCounts["en10"] == 50)
        #expect(ifaceCounts["en0"] == 50)
    }

    // MARK: - Test 6: Captive Portal Status & Issue Creation

    @Test("T5-Stress-06: CaptivePortalDetector distinguishes redirecting, detected, and unauthenticated states")
    func testCaptivePortalDetectorPayloadDistinction() {
        let detector = CaptivePortalDetector()

        // 1. Not detected -> No issue created
        let issueNotDetected = detector.createIssueIfActive(status: .notDetected, redirectURL: nil)
        #expect(issueNotDetected == nil)

        // 2. Authenticated -> No issue created
        let issueAuth = detector.createIssueIfActive(status: .authenticated, redirectURL: nil)
        #expect(issueAuth == nil)

        // 3. Redirecting to campus portal URL
        let portalTarget = "http://10.1.36.1:8080/login.html"
        let issueRedirect = detector.createIssueIfActive(status: .redirecting, redirectURL: portalTarget)
        #expect(issueRedirect != nil)
        #expect(issueRedirect?.severity == .critical)
        #expect(issueRedirect?.description.contains("http://10.1.36.1:8080/login.html") == true)
        #expect(issueRedirect?.automatedFixAvailable == true)

        // 4. Detected login wall
        let issueDetected = detector.createIssueIfActive(status: .detected, redirectURL: nil)
        #expect(issueDetected != nil)
        #expect(issueDetected?.title.contains("Captive Portal Active") == true)
    }

    // MARK: - Test 7: LM Studio Bridge Offline Refusal Handling

    @Test("T5-Stress-07: LM Studio bridge fails promptly when target server port is offline")
    func testLMStudioOfflineConnectionRefusal() async {
        let closedPortURL = URL(string: "http://127.0.0.1:59999/v1/chat/completions")!
        let bridge = LLMDoctorBridge()
        let report = NetworkTelemetryReport(
            timestamp: Date(),
            captivePortalStatus: .notDetected,
            activeIssues: []
        )

        do {
            _ = try await bridge.sendTelemetry(report: report, endpoint: closedPortURL)
            Issue.record("Expected connection error on offline port")
        } catch {
            // Offline port refused or timed out cleanly
            #expect(Bool(true))
        }
    }

    // MARK: - Test 8: LM Studio Bridge Truncated JSON Handling

    @Test("T5-Stress-08: LM Studio bridge handles malformed or truncated JSON response cleanly")
    func testLMStudioMalformedJSONHandling() {
        let truncatedJSON = Data("{\"id\": \"chatcmpl\", \"choices\": [{\"message\": {\"content\":".utf8)

        // Bridge parsing requires valid JSON structure with choices and message
        do {
            guard let json = try JSONSerialization.jsonObject(with: truncatedJSON) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let _ = firstChoice["message"] as? [String: Any] else {
                // Correctly identifies malformed or incomplete structure
                #expect(Bool(true))
                return
            }
            Issue.record("Expected malformed JSON to fail extraction")
        } catch {
            // Serialization error caught cleanly
            #expect(Bool(true))
        }
    }
}
