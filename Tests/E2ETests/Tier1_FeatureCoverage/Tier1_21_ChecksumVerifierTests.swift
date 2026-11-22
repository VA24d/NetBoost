import Testing
import Foundation
@testable import NetBoostCore

@Suite("Feature 21: Checksum Integrity Verifier", .tags(.tier1, .m4_downloader))
struct Tier1_21_ChecksumVerifierTests {

    struct ChecksumVerifier {
        enum Algorithm {
            case md5
            case sha1
            case sha256
        }

        static func computeHex(data: Data, algorithm: Algorithm) -> String {
            switch algorithm {
            case .md5:
                return TestAssertions.md5Hex(of: data)
            case .sha1:
                return TestAssertions.sha1Hex(of: data)
            case .sha256:
                return TestAssertions.sha256Hex(of: data)
            }
        }

        static func verify(data: Data, expectedHash: String, algorithm: Algorithm) -> Bool {
            let computed = computeHex(data: data, algorithm: algorithm)
            return computed.caseInsensitiveCompare(expectedHash) == .orderedSame
        }
    }

    @Test("T1-F21-01: Calculate and verify MD5 checksum against expected hash")
    func testMD5ChecksumVerification() {
        let testData = "NetBoost Download Accelerator".data(using: .utf8)!
        let expectedMD5 = TestAssertions.md5Hex(of: testData)

        let isMatch = ChecksumVerifier.verify(data: testData, expectedHash: expectedMD5, algorithm: .md5)
        #expect(isMatch == true)

        let isMismatch = ChecksumVerifier.verify(data: testData, expectedHash: "00112233445566778899aabbccddeeff", algorithm: .md5)
        #expect(isMismatch == false)
    }

    @Test("T1-F21-02: Calculate and verify SHA-1 checksum against expected hash")
    func testSHA1ChecksumVerification() {
        let testData = "NetBoost SHA1 Validation".data(using: .utf8)!
        let expectedSHA1 = TestAssertions.sha1Hex(of: testData)

        let isMatch = ChecksumVerifier.verify(data: testData, expectedHash: expectedSHA1, algorithm: .sha1)
        #expect(isMatch == true)
    }

    @Test("T1-F21-03: Calculate and verify SHA-256 checksum against expected hash")
    func testSHA256ChecksumVerification() {
        let testData = "NetBoost High Speed 16 Chunks".data(using: .utf8)!
        let expectedSHA256 = TestAssertions.sha256Hex(of: testData)

        let isMatch = ChecksumVerifier.verify(data: testData, expectedHash: expectedSHA256, algorithm: .sha256)
        #expect(isMatch == true)
    }

    @Test("T1-F21-04: Case-insensitive hexadecimal hash comparison")
    func testCaseInsensitiveHashComparison() {
        let testData = "Hello".data(using: .utf8)!
        let lowerHash = TestAssertions.sha256Hex(of: testData).lowercased()
        let upperHash = lowerHash.uppercased()

        let matchLower = ChecksumVerifier.verify(data: testData, expectedHash: lowerHash, algorithm: .sha256)
        let matchUpper = ChecksumVerifier.verify(data: testData, expectedHash: upperHash, algorithm: .sha256)

        #expect(matchLower == true)
        #expect(matchUpper == true)
    }

    @Test("T1-F21-05: Deterministic payload hashing consistency")
    func testDeterministicPayloadHashing() {
        let payload1 = TestAssertions.generateDeterministicPayload(size: 65536)
        let payload2 = TestAssertions.generateDeterministicPayload(size: 65536)

        let hash1 = TestAssertions.sha256Hex(of: payload1)
        let hash2 = TestAssertions.sha256Hex(of: payload2)

        #expect(hash1 == hash2)
        #expect(!hash1.isEmpty)
    }
}
