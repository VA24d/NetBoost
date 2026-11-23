import Testing
import Foundation
@testable import NetBoostCore

@Suite("Downloader: ChecksumValidator Unit Tests", .tags(.tier1, .m4_downloader))
struct ChecksumValidatorTests {

    private func makeTemporaryFileURL(with data: Data) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("netboost-checksum-\(UUID().uuidString).bin")
        try data.write(to: fileURL)
        return fileURL
    }

    @Test("Calculate and verify MD5 checksum for in-memory and disk file")
    func testMD5ChecksumVerification() async throws {
        let testData = "NetBoost MD5 Validation Test".data(using: .utf8)!
        let expectedMD5 = TestAssertions.md5Hex(of: testData)

        let isMatchData = ChecksumValidator.validate(data: testData, expectedChecksum: expectedMD5, algorithm: .md5)
        #expect(isMatchData == true)

        let fileURL = try makeTemporaryFileURL(with: testData)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let isMatchFile = try await ChecksumValidator.validate(fileURL: fileURL, expectedChecksum: expectedMD5)
        #expect(isMatchFile == true)
    }

    @Test("Calculate and verify SHA-1 checksum for in-memory and disk file")
    func testSHA1ChecksumVerification() async throws {
        let testData = "NetBoost SHA1 Validation Test".data(using: .utf8)!
        let expectedSHA1 = TestAssertions.sha1Hex(of: testData)

        let isMatchData = ChecksumValidator.validate(data: testData, expectedChecksum: expectedSHA1, algorithm: .sha1)
        #expect(isMatchData == true)

        let fileURL = try makeTemporaryFileURL(with: testData)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let isMatchFile = try await ChecksumValidator.validate(fileURL: fileURL, expectedChecksum: expectedSHA1)
        #expect(isMatchFile == true)
    }

    @Test("Calculate and verify SHA-256 checksum for in-memory and disk file")
    func testSHA256ChecksumVerification() async throws {
        let testData = TestAssertions.generateDeterministicPayload(size: 65536)
        let expectedSHA256 = TestAssertions.sha256Hex(of: testData)

        let isMatchData = ChecksumValidator.validate(data: testData, expectedChecksum: expectedSHA256, algorithm: .sha256)
        #expect(isMatchData == true)

        let fileURL = try makeTemporaryFileURL(with: testData)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let isMatchFile = try await ChecksumValidator.validate(fileURL: fileURL, expectedChecksum: expectedSHA256)
        #expect(isMatchFile == true)
    }

    @Test("Case-insensitive hexadecimal hash matching succeeds")
    func testCaseInsensitiveHashMatching() {
        let testData = "Hello NetBoost".data(using: .utf8)!
        let lowerHex = TestAssertions.sha256Hex(of: testData)
        let upperHex = lowerHex.uppercased()

        let matchLower = ChecksumValidator.validate(data: testData, expectedChecksum: lowerHex)
        let matchUpper = ChecksumValidator.validate(data: testData, expectedChecksum: upperHex)

        #expect(matchLower == true)
        #expect(matchUpper == true)
    }

    @Test("Standard empty digests produce well-known values")
    func testEmptyDataDigests() {
        let empty = Data()
        let sha256 = ChecksumValidator().computeChecksum(for: empty, algorithm: .sha256)
        let md5 = ChecksumValidator().computeChecksum(for: empty, algorithm: .md5)
        let sha1 = ChecksumValidator().computeChecksum(for: empty, algorithm: .sha1)

        #expect(sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(md5 == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(sha1 == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    @Test("Single-byte corruption triggers verification failure")
    func testSingleByteCorruptionFailure() async throws {
        var originalData = TestAssertions.generateDeterministicPayload(size: 8192)
        let originalHash = TestAssertions.sha256Hex(of: originalData)

        originalData[50] ^= 0xFF
        let fileURL = try makeTemporaryFileURL(with: originalData)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let isMatch = try await ChecksumValidator.validate(fileURL: fileURL, expectedChecksum: originalHash)
        #expect(isMatch == false)
    }

    @Test("Algorithm auto-detection correctly parses hash lengths")
    func testAlgorithmDetection() {
        #expect(ChecksumAlgorithm.detect(from: "d41d8cd98f00b204e9800998ecf8427e") == .md5)
        #expect(ChecksumAlgorithm.detect(from: "da39a3ee5e6b4b0d3255bfef95601890afd80709") == .sha1)
        #expect(ChecksumAlgorithm.detect(from: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") == .sha256)
        #expect(ChecksumAlgorithm.detect(from: "unknown_length") == nil)
    }
}
