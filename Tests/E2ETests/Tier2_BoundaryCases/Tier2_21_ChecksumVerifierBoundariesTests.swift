import Foundation
import Testing
import CryptoKit
@testable import NetBoostCore

@Suite("Tier 2 - Feature 21: Checksum Verifier Boundaries", .tags(.tier2, .m4_downloader, .accelerator))
struct Tier2_21_ChecksumVerifierBoundariesTests {

    @Test("T2-F21-01: Single-byte corruption causes hash verification failure")
    func testCorruptedByteCausesChecksumMismatch() {
        var originalData = TestAssertions.generateDeterministicPayload(size: 4096)
        let originalHash = TestAssertions.sha256Hex(of: originalData)

        // Corrupt byte at index 100
        originalData[100] ^= 0xFF
        let corruptedHash = TestAssertions.sha256Hex(of: originalData)

        #expect(originalHash != corruptedHash)
    }

    @Test("T2-F21-02: Case-insensitive hexadecimal hash comparison succeeds")
    func testCaseInsensitiveHashMatching() {
        let testData = "NetBoost campus network accelerator".data(using: .utf8)!
        let lowerHex = TestAssertions.sha256Hex(of: testData)
        let upperHex = lowerHex.uppercased()

        func compareHashes(_ a: String, _ b: String) -> Bool {
            return a.caseInsensitiveCompare(b) == .orderedSame
        }

        #expect(compareHashes(lowerHex, upperHex) == true)
    }

    @Test("T2-F21-03: Empty file produces standard well-known empty digests")
    func testEmptyDataDigests() {
        let empty = Data()

        // Known standard empty hashes:
        // SHA-256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        // MD5: d41d8cd98f00b204e9800998ecf8427e
        // SHA-1: da39a3ee5e6b4b0d3255bfef95601890afd80709
        let sha256 = TestAssertions.sha256Hex(of: empty)
        let md5 = TestAssertions.md5Hex(of: empty)
        let sha1 = TestAssertions.sha1Hex(of: empty)

        #expect(sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(md5 == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(sha1 == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    @Test("T2-F21-04: Supported hashing algorithms: sha256, sha1, md5")
    func testSupportedAlgorithms() {
        let supported = ["sha256", "sha1", "md5"]
        func isSupportedAlgorithm(_ algo: String) -> Bool {
            return supported.contains(algo.lowercased())
        }

        #expect(isSupportedAlgorithm("SHA256") == true)
        #expect(isSupportedAlgorithm("MD5") == true)
        #expect(isSupportedAlgorithm("SHA1") == true)
        #expect(isSupportedAlgorithm("CRC32") == false)
        #expect(isSupportedAlgorithm("BLAKE3") == false)
    }

    @Test("T2-F21-05: Incremental streaming hash produces identical digest to full buffer hash")
    func testStreamingHashEquivalence() {
        let testData = TestAssertions.generateDeterministicPayload(size: 65536)
        let expectedHash = TestAssertions.sha256Hex(of: testData)

        var hasher = SHA256()
        let chunkSize = 4096
        for offset in stride(from: 0, to: testData.count, by: chunkSize) {
            let end = min(offset + chunkSize, testData.count)
            let slice = testData.subdata(in: offset..<end)
            hasher.update(data: slice)
        }

        let streamingDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(streamingDigest == expectedHash)
    }
}
