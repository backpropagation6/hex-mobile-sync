import Foundation

/// Shared JSON configuration for every file format in this package.
///
/// Dates are ISO 8601 strings. Decoding accepts both whole-second
/// (`2026-11-01T10:00:00Z`) and fractional-second
/// (`2026-11-01T10:00:00.250Z`) forms, with `Z` or a numeric offset.
/// Encoding always writes UTC with millisecond precision.
enum HexJSON {
    /// Creates a decoder configured for the package's file formats.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 date, found \"\(string)\"."
                )
            }
            return date
        }
        return decoder
    }

    /// Creates an encoder producing stable, human-readable output
    /// (sorted keys, pretty printed, unescaped slashes).
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return encoder
    }

    /// Parses an ISO 8601 timestamp with or without fractional seconds.
    static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(trimmed)
    }

    /// Formats a date as UTC ISO 8601 with millisecond precision.
    static func formatDate(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Maps a decoding failure to a short human-readable description.
    static func describe(_ error: any Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return String(describing: error)
        }
        switch decodingError {
        case let .dataCorrupted(context):
            return context.debugDescription
        case let .keyNotFound(key, context):
            return "Missing key \"\(key.stringValue)\" at \(path(context))."
        case let .typeMismatch(type, context):
            return "Expected \(type) at \(path(context)). \(context.debugDescription)"
        case let .valueNotFound(type, context):
            return "Missing \(type) value at \(path(context))."
        @unknown default:
            return String(describing: decodingError)
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let components = context.codingPath.map(\.stringValue)
        return components.isEmpty ? "the root" : components.joined(separator: ".")
    }
}

/// Decodes any JSON value and discards it. Used to step over malformed
/// elements of an array without failing the whole document.
private struct DiscardedJSONValue: Decodable {
    init(from decoder: any Decoder) throws {}
}

extension KeyedDecodingContainer {
    /// Decodes an array leniently.
    ///
    /// - A missing key, `null`, or a value that is not an array yields `[]`.
    /// - Elements that fail to decode as `Element` are skipped.
    func decodeLossyArray<Element: Decodable>(
        _ type: Element.Type,
        forKey key: Key
    ) -> [Element] {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return [] }
        guard var array = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [Element] = []
        if let count = array.count { result.reserveCapacity(count) }
        while !array.isAtEnd {
            if let element = try? array.decode(Element.self) {
                result.append(element)
            } else if (try? array.decode(DiscardedJSONValue.self)) == nil {
                // Could not even step over the element; stop rather than loop forever.
                break
            }
        }
        return result
    }

    /// Decodes an optional value leniently: missing, `null`, or a value of the
    /// wrong type all yield `nil` instead of throwing.
    func decodeLenient<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        (try? decodeIfPresent(Value.self, forKey: key)) ?? nil
    }
}

extension KeyedDecodingContainer {
    /// Validates `schema_version` against the newest version this package
    /// understands.
    ///
    /// - Throws: ``SyncCodecError/missingSchemaVersion`` when the key is absent
    ///   or not an integer, ``SyncCodecError/unsupportedSchemaVersion(found:supported:)``
    ///   when it is below 1 or above `supported`.
    func validateSchemaVersion(forKey key: Key, supported: Int) throws -> Int {
        guard let version = decodeLenient(Int.self, forKey: key) else {
            throw SyncCodecError.missingSchemaVersion
        }
        guard (1...supported).contains(version) else {
            throw SyncCodecError.unsupportedSchemaVersion(found: version, supported: supported)
        }
        return version
    }
}
