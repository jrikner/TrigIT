/// A MIDI note to trigger: Note On, then a matching Note Off shortly after.
public struct MIDINote: Hashable, Sendable, Codable {
    /// 0...15 (shown to people as 1...16).
    public var channel: UInt8
    /// 0...127.
    public var note: UInt8
    /// 1...127 (a Note On with velocity 0 means Note Off).
    public var velocity: UInt8

    public init(channel: UInt8, note: UInt8, velocity: UInt8 = 127) {
        self.channel = min(channel, 15)
        self.note = min(note, 127)
        self.velocity = min(max(velocity, 1), 127)
    }

    public var noteOn: [UInt8] { [0x90 | channel, note, velocity] }
    public var noteOff: [UInt8] { [0x80 | channel, note, 0] }

    /// Note name with octave, middle C (60) as C3, as Ableton names it.
    public var noteName: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[Int(note) % 12])\(Int(note) / 12 - 2)"
    }
}

/// A MIDI Show Control command (MSC 1.0), sent as SysEx:
/// F0 7F <device ID> 02 <command format> <command> <data> F7.
public struct MSCCommand: Hashable, Sendable, Codable {
    public enum Command: UInt8, Hashable, Sendable, Codable, CaseIterable {
        case go = 0x01
        case stop = 0x02
        case resume = 0x03

        public var name: String {
            switch self {
            case .go: return "GO"
            case .stop: return "STOP"
            case .resume: return "RESUME"
            }
        }
    }

    /// Common command formats. Any value 0x01...0x7F is allowed.
    public enum Format {
        public static let lighting: UInt8 = 0x01
        public static let movingLights: UInt8 = 0x02
        public static let allTypes: UInt8 = 0x7F
    }

    /// 0x00...0x6F a single device, 0x70...0x7E a group, 0x7F all devices.
    public var deviceID: UInt8
    public var commandFormat: UInt8
    public var command: Command
    /// Cue number such as "5" or "12.5"; empty for the next cue.
    public var cue: String
    /// Cue list (grandMA3: the executor's sequence); empty for the default list. Needs a cue.
    public var list: String

    public init(deviceID: UInt8 = 0x7F, commandFormat: UInt8 = Format.allTypes, command: Command = .go,
                cue: String = "", list: String = "") {
        self.deviceID = min(deviceID, 0x7F)
        self.commandFormat = min(max(commandFormat, 1), 0x7F)
        self.command = command
        self.cue = cue
        self.list = list
    }

    /// Cue and list must be numbers with at most one decimal point, and a list
    /// needs a cue.
    public var isValid: Bool {
        Self.isCueNumber(cue, allowEmpty: true) && Self.isCueNumber(list, allowEmpty: true) && (list.isEmpty || !cue.isEmpty)
    }

    public var encoded: [UInt8] {
        var bytes: [UInt8] = [0xF0, 0x7F, deviceID, 0x02, commandFormat, command.rawValue]
        if !cue.isEmpty {
            bytes += Array(cue.utf8)
            if !list.isEmpty {
                bytes.append(0x00)
                bytes += Array(list.utf8)
            }
        }
        bytes.append(0xF7)
        return bytes
    }

    public var summary: String {
        var text = "MSC \(command.name)"
        if !cue.isEmpty { text += " cue \(cue)" }
        if !list.isEmpty { text += " list \(list)" }
        return text
    }

    private static func isCueNumber(_ text: String, allowEmpty: Bool) -> Bool {
        if text.isEmpty { return allowEmpty }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count <= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
    }
}
