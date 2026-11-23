import Foundation

public struct RangeProbeResult: Sendable, Equatable {
    public let supportsRanges: Bool
    public let contentLength: Int64
    public let etag: String?
    public let lastModified: String?
    public let filename: String
    public let suggestedChunkCount: Int
    public let mimeType: String?

    public init(
        supportsRanges: Bool,
        contentLength: Int64,
        etag: String? = nil,
        lastModified: String? = nil,
        filename: String,
        suggestedChunkCount: Int,
        mimeType: String? = nil
    ) {
        self.supportsRanges = supportsRanges
        self.contentLength = contentLength
        self.etag = etag
        self.lastModified = lastModified
        self.filename = filename
        self.suggestedChunkCount = suggestedChunkCount
        self.mimeType = mimeType
    }
}

public protocol RangeProbeProtocol: Sendable {
    func probe(url: URL) async throws -> RangeProbeResult
}

public final class RangeProbe: RangeProbeProtocol, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func probe(url: URL, session: URLSession = .shared) async throws -> RangeProbeResult {
        let prober = RangeProbe(session: session)
        return try await prober.probe(url: url)
    }

    public func probe(url: URL) async throws -> RangeProbeResult {
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 10.0

        do {
            let (_, response) = try await session.data(for: headRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            // If HEAD is not allowed (405) or not implemented (501), fallback to GET Range probe
            if httpResponse.statusCode == 405 || httpResponse.statusCode == 501 {
                return try await probeWithGetRange(url: url)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw URLError(URLError.Code(rawValue: httpResponse.statusCode))
            }

            let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges")
            let lengthHeader = httpResponse.value(forHTTPHeaderField: "Content-Length")
            let etag = httpResponse.value(forHTTPHeaderField: "ETag")
            let lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")
            let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")
            let mimeType = httpResponse.value(forHTTPHeaderField: "Content-Type")

            let length: Int64
            if let lh = lengthHeader, let parsed = Int64(lh) {
                length = parsed
            } else if httpResponse.expectedContentLength > 0 {
                length = httpResponse.expectedContentLength
            } else {
                length = 0
            }

            let supportsRanges = acceptRanges?.lowercased() == "bytes"
            let filename = Self.parseFilename(from: contentDisposition, fallbackURL: url)
            let suggestedChunks = Self.calculateSuggestedChunkCount(fileSize: length, supportsRanges: supportsRanges)

            return RangeProbeResult(
                supportsRanges: supportsRanges,
                contentLength: length,
                etag: etag,
                lastModified: lastModified,
                filename: filename,
                suggestedChunkCount: suggestedChunks,
                mimeType: mimeType
            )
        } catch let error as URLError {
            // Rethrow specific network/server errors
            throw error
        } catch {
            // Try fallback GET range probe if HEAD had non-terminal issue
            return try await probeWithGetRange(url: url)
        }
    }

    private func probeWithGetRange(url: URL) async throws -> RangeProbeResult {
        var getRequest = URLRequest(url: url)
        getRequest.httpMethod = "GET"
        getRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        getRequest.timeoutInterval = 10.0

        let (_, response) = try await session.data(for: getRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
            throw URLError(URLError.Code(rawValue: httpResponse.statusCode))
        }

        let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges")
        let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range")
        let etag = httpResponse.value(forHTTPHeaderField: "ETag")
        let lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")
        let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")
        let mimeType = httpResponse.value(forHTTPHeaderField: "Content-Type")

        var length: Int64 = 0
        var supportsRanges = false

        if httpResponse.statusCode == 206 {
            supportsRanges = true
            if let cr = contentRange, let slashIdx = cr.lastIndex(of: "/") {
                let totalPart = String(cr[cr.index(after: slashIdx)...]).trimmingCharacters(in: .whitespaces)
                if let parsed = Int64(totalPart) {
                    length = parsed
                }
            }
        } else {
            supportsRanges = acceptRanges?.lowercased() == "bytes"
            if let lh = httpResponse.value(forHTTPHeaderField: "Content-Length"), let parsed = Int64(lh) {
                length = parsed
            } else if httpResponse.expectedContentLength > 0 {
                length = httpResponse.expectedContentLength
            }
        }

        let filename = Self.parseFilename(from: contentDisposition, fallbackURL: url)
        let suggestedChunks = Self.calculateSuggestedChunkCount(fileSize: length, supportsRanges: supportsRanges)

        return RangeProbeResult(
            supportsRanges: supportsRanges,
            contentLength: length,
            etag: etag,
            lastModified: lastModified,
            filename: filename,
            suggestedChunkCount: suggestedChunks,
            mimeType: mimeType
        )
    }

    public static func parseFilename(from contentDisposition: String?, fallbackURL: URL) -> String {
        if let cd = contentDisposition, let nameRange = cd.range(of: "filename=") {
            let remainder = cd[nameRange.upperBound...]
            let rawName = remainder.components(separatedBy: ";").first ?? ""
            let trimmed = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "\" '"))
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let last = fallbackURL.lastPathComponent
        return last.isEmpty || last == "/" ? "download.bin" : last
    }

    public static func calculateSuggestedChunkCount(fileSize: Int64, supportsRanges: Bool) -> Int {
        guard supportsRanges else { return 1 }
        if fileSize < 1_048_576 { return 1 }
        if fileSize > 104_857_600 { return 16 }
        return 8
    }
}
