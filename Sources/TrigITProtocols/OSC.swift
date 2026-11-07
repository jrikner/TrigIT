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
