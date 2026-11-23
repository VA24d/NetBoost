import Foundation

/// Serializes network telemetry reports, route tables, and diagnostic probe states into clean JSON.
public struct TelemetryExporter: Sendable {

    /// Exports a `NetworkTelemetryReport` to a JSON string.
    /// - Parameters:
    ///   - report: The telemetry report model to serialize.
    ///   - pretty: If true, formats with indentation and line breaks.
    /// - Returns: Serialized JSON UTF-8 string.
    public static func exportJSON(report: NetworkTelemetryReport, pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }

        let data = try encoder.encode(report)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return jsonString
    }

    /// Decodes a `NetworkTelemetryReport` from a JSON string.
    public static func importJSON(_ json: String) throws -> NetworkTelemetryReport {
        guard let data = json.data(using: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NetworkTelemetryReport.self, from: data)
    }
}
