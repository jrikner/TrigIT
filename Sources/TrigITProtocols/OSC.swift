// SPDX-License-Identifier: GPL-3.0-or-later

/// One OSC argument. TrigIT sends the three core OSC 1.0 types.
public enum OSCArgument: Hashable, Sendable, CustomStringConvertible {
    case int(Int32)
    case float(Float)
    case string(String)

    var typeTag: UInt8 {
        switch self {
        case .int: return UInt8(ascii: "i")
        case .float: return UInt8(ascii: "f")
        case .string: return UInt8(ascii: "s")
        }
    }

    /// The argument as typed in the editor: ints and floats bare, strings in
    /// quotes unless they are a single word that isn't a number.
    public var description: String {
        switch self {
        case .int(let value): return String(value)
        case .float(let value):
            let text = String(value)
            return text.contains(".") || text.contains("e") ? text : text + ".0"
        case .string(let value):
            let needsQuotes = value.isEmpty || value.contains(where: \.isWhitespace) || value.contains("\"")
                || Int32(value) != nil || Float(value) != nil
            return needsQuotes ? "\"" + value.replacingAll("\"", with: "\\\"") + "\"" : value
        }
    }
}

extension OSCArgument: Codable {
    private enum CodingKeys: String, CodingKey {
        case int, float, string
    }

    /// Written as `{"int": 1}`, `{"float": 0.5}` or `{"string": "go"}`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try c.decodeIfPresent(Int32.self, forKey: .int) {
            self = .int(value)
        } else if let value = try c.decodeIfPresent(Float.self, forKey: .float) {
            self = .float(value)
        } else if let value = try c.decodeIfPresent(String.self, forKey: .string) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "an OSC argument needs \"int\", \"float\" or \"string\""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .int(let value): try c.encode(value, forKey: .int)
        case .float(let value): try c.encode(value, forKey: .float)
        case .string(let value): try c.encode(value, forKey: .string)
        }
    }
}

/// An OSC message: an address pattern and its arguments.
public struct OSCMessage: Hashable, Sendable, Codable, CustomStringConvertible {
    public var address: String
    public var arguments: [OSCArgument]

    public init(address: String, arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    /// OSC addresses start with "/" and contain only printable ASCII without
    /// spaces, '#' or ','.
    public var hasValidAddress: Bool {
        address.first == "/" && address.utf8.allSatisfy { byte in
            byte > 0x20 && byte < 0x7F && byte != UInt8(ascii: "#") && byte != UInt8(ascii: ",")
        }
    }

    public var description: String {
        ([address] + arguments.map(\.description)).joined(separator: " ")
    }

    /// The message as an OSC 1.0 packet: the padded address, the padded type
    /// tag string, then each argument, all big-endian and 4-byte aligned.
    public func encoded() -> [UInt8] {
        var bytes: [UInt8] = []
        appendPaddedString(Array(address.utf8), to: &bytes)
        appendPaddedString([UInt8(ascii: ",")] + arguments.map(\.typeTag), to: &bytes)
        for argument in arguments {
            switch argument {
            case .int(let value): appendBigEndian(UInt32(bitPattern: value), to: &bytes)
            case .float(let value): appendBigEndian(value.bitPattern, to: &bytes)
            case .string(let value): appendPaddedString(Array(value.utf8), to: &bytes)
            }
        }
        return bytes
    }
}

extension OSCArgument {
    /// Parses arguments typed as text, separated by spaces. Whole numbers
    /// become ints, numbers with a decimal point become floats, anything else
    /// becomes a string. Quote a string to keep spaces or to send a number as
    /// text: `"two words"`, `"42"`. Returns nil for an unterminated quote.
    public static func parseList(_ text: String) -> [OSCArgument]? {
        var arguments: [OSCArgument] = []
        var characters = Substring(text)
        while true {
            characters = characters.drop(while: \.isWhitespace)
            guard let first = characters.first else { return arguments }
            if first == "\"" {
                var value = ""
                var index = characters.index(after: characters.startIndex)
                var closed = false
                while index < characters.endIndex {
                    let character = characters[index]
                    if character == "\\", characters.index(after: index) < characters.endIndex {
                        index = characters.index(after: index)
                        value.append(characters[index])
                    } else if character == "\"" {
                        closed = true
                        break
                    } else {
                        value.append(character)
                    }
                    index = characters.index(after: index)
                }
                guard closed else { return nil }
                arguments.append(.string(value))
                characters = characters[characters.index(after: index)...]
            } else {
                let token = characters.prefix { !$0.isWhitespace }
                characters = characters.dropFirst(token.count)
                arguments.append(parseToken(String(token)))
            }
        }
    }

    private static func parseToken(_ token: String) -> OSCArgument {
        if let int = Int32(token) { return .int(int) }
        if token.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let float = Float(token), float.isFinite {
            return .float(float)
        }
        return .string(token)
    }
}

// MARK: - Byte helpers

private func appendPaddedString(_ utf8: [UInt8], to bytes: inout [UInt8]) {
    bytes += utf8
    bytes.append(0)
    while bytes.count % 4 != 0 { bytes.append(0) }
}

private func appendBigEndian(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes += [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

extension String {
    func replacingAll(_ target: Character, with replacement: String) -> String {
        reduce(into: "") { result, character in
            if character == target { result += replacement } else { result.append(character) }
        }
    }
}

// MARK: - Decoding

extension OSCMessage {
    /// Reads an OSC 1.0 packet. A bundle yields its first message. Arguments
    /// become the three types TrigIT sends: int64 → int (if it fits),
    /// double → float, symbol → string, true/false → int 1/0; nil and
    /// impulse are dropped. Returns nil for a malformed packet, an invalid
    /// address, or a blob or other type TrigIT can't send back.
    public init?(decoding bytes: [UInt8]) {
        var reader = OSCReader(bytes: bytes[...])
        guard let address = reader.string() else { return nil }
        if address == "#bundle" {
            // Time tag, then elements: size and content.
            guard reader.take(8) != nil, let size = reader.int32(), size > 0, let element = reader.take(Int(size)) else { return nil }
            self.init(decoding: Array(element))
            return
        }
        // OSC 1.0 lets old senders omit the type tag string; treat that as no arguments.
        let tags = reader.isAtEnd ? "," : reader.string()
        guard let tags, tags.first == "," else { return nil }
        var arguments: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i": guard let v = reader.int32() else { return nil }; arguments.append(.int(v))
            case "f": guard let v = reader.uint32() else { return nil }; arguments.append(.float(Float(bitPattern: v)))
            case "s", "S": guard let v = reader.string() else { return nil }; arguments.append(.string(v))
            case "h":
                guard let high = reader.uint32(), let low = reader.uint32(),
                      let v = Int32(exactly: Int64(bitPattern: UInt64(high) << 32 | UInt64(low))) else { return nil }
                arguments.append(.int(v))
            case "d":
                guard let high = reader.uint32(), let low = reader.uint32() else { return nil }
                arguments.append(.float(Float(Double(bitPattern: UInt64(high) << 32 | UInt64(low)))))
            case "T": arguments.append(.int(1))
            case "F": arguments.append(.int(0))
            case "N", "I": continue
            default: return nil
            }
        }
        self.init(address: address, arguments: arguments)
        guard hasValidAddress else { return nil }
    }
}

private struct OSCReader {
    var bytes: ArraySlice<UInt8>

    var isAtEnd: Bool { bytes.isEmpty }

    mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, bytes.count >= count else { return nil }
        defer { bytes = bytes.dropFirst(count) }
        return bytes.prefix(count)
    }

    mutating func uint32() -> UInt32? {
        take(4)?.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func int32() -> Int32? {
        uint32().map { Int32(bitPattern: $0) }
    }

    /// A null-terminated string padded to a multiple of 4 bytes.
    mutating func string() -> String? {
        guard let end = bytes.firstIndex(of: 0) else { return nil }
        let length = end - bytes.startIndex
        let text = String(decoding: bytes.prefix(length), as: UTF8.self)
        return take((length / 4 + 1) * 4) == nil ? nil : text
    }
}
