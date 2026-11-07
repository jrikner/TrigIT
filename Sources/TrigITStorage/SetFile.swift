import Foundation
import TrigITEngine

/// A Set's file: readable JSON that can be copied, emailed, versioned in git
/// and opened on another Mac.
///
///     {
///       "format" : "TrigIT Set",
///       "version" : 1,
///       "set" : { "id": …, "name": …, "stopTime": …, "destinations": […], "songs": […] }
///     }
///
/// `version` goes up only when a change would stop older TrigIT from reading
/// the file correctly. Adding an optional field doesn't need it: older files
/// lacking it still open, with the default.
public enum SetFile {
    public static let formatName = "TrigIT Set"
    public static let currentVersion = 1
    public static let fileExtension = "trigit"

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case notJSON
        case notATrigITSet
        case newerVersion(Int)
        case invalid(String)

        public var description: String {
            switch self {
            case .unreadable(let reason): return "The file could not be read: \(reason)."
            case .notJSON: return "The file is not a TrigIT Set (it isn't JSON)."
            case .notATrigITSet: return "The file is JSON, but not a TrigIT Set."
            case .newerVersion(let version):
                return "The Set was saved by a newer TrigIT (file version \(version)); update TrigIT to open it."
            case .invalid(let reason): return "The Set file is damaged: \(reason)."
            }
        }
    }

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var set: ShowSet?
    }

    private struct Header: Decodable {
        var format: String?
        var version: Int?
    }

    public static func encode(_ set: ShowSet) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Envelope(format: formatName, version: currentVersion, set: set))
    }

    public static func decode(_ data: Data) throws -> ShowSet {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw ReadError.notJSON }
        let decoder = JSONDecoder()
        // Check the header first, so a newer or foreign file gets a clear message.
        guard let header = try? decoder.decode(Header.self, from: data), header.format == formatName,
              let version = header.version
        else { throw ReadError.notATrigITSet }
        guard version <= currentVersion else { throw ReadError.newerVersion(version) }
        do {
            guard let set = try decoder.decode(Envelope.self, from: data).set else {
                throw ReadError.invalid("it has no \"set\"")
            }
            return set
        } catch let error as ReadError {
            throw error
        } catch let error as DecodingError {
            throw ReadError.invalid(describe(error))
        }
    }

    public static func read(from url: URL) throws -> ShowSet {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReadError.unreadable(error.localizedDescription)
        }
        return try decode(data)
    }

    /// Writes atomically: a crash mid-write never leaves a half-written Set.
    public static func write(_ set: ShowSet, to url: URL) throws {
        try encode(set).write(to: url, options: .atomic)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return keys.isEmpty ? "" : " at \(keys.hasPrefix(".") ? String(keys.dropFirst()) : keys)"
        }
        switch error {
        case .dataCorrupted(let context): return context.debugDescription + path(context)
        case .keyNotFound(let key, let context): return "\"\(key.stringValue)\" is missing" + path(context)
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return context.debugDescription + path(context)
        @unknown default: return "\(error)"
        }
    }
}
