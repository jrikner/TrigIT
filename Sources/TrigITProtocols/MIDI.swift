// SPDX-License-Identifier: GPL-3.0-or-later

/// A MIDI 1.0 message TrigIT cares about.
public enum MIDIMessage: Hashable, Sendable {
    /// Note On with velocity above 0. `channel` is 0-based.
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    /// Note Off, or Note On with velocity 0.
    case noteOff(channel: UInt8, note: UInt8)
    /// MIDI Time Code quarter-frame data byte (the byte after 0xF1).
    case quarterFrame(UInt8)
    /// A complete System Exclusive message, from 0xF0 to 0xF7 inclusive.
    case systemExclusive([UInt8])
}

/// Turns a stream of raw MIDI bytes into messages. Handles running status,
/// real-time bytes interleaved anywhere (even inside SysEx), and SysEx split
/// across packets. Messages TrigIT doesn't use are skipped.
public struct MIDIParser: Sendable {
    /// Longest SysEx kept; longer ones are dropped (MTC full frames are 10 bytes).
    public static let maxSystemExclusiveLength = 256

    private var status: UInt8?
    private var data: [UInt8] = []
    private var sysEx: [UInt8]?

    public init() {}

    public mutating func parse(_ bytes: [UInt8]) -> [MIDIMessage] {
        var messages: [MIDIMessage] = []
        for byte in bytes {
            if let message = parse(byte) { messages.append(message) }
        }
        return messages
    }

    private mutating func parse(_ byte: UInt8) -> MIDIMessage? {
        switch byte {
        case 0xF8...0xFF:
            // Real-time messages are one byte and may appear anywhere.
            return nil
        case 0xF0:
            sysEx = [byte]
            status = nil
            return nil
        case 0xF7:
            defer { sysEx = nil }
            guard var message = sysEx else { return nil }
            message.append(byte)
            return .systemExclusive(message)
        case 0x80...0xEF, 0xF1...0xF6:
            sysEx = nil
            status = byte
            data.removeAll(keepingCapacity: true)
            if byte == 0xF6 { status = nil } // Tune Request has no data
            return nil
        default:
            if sysEx != nil {
                sysEx!.append(byte)
                if sysEx!.count > Self.maxSystemExclusiveLength { sysEx = nil }
                return nil
            }
            guard let status else { return nil }
            data.append(byte)
            guard data.count == Self.dataLength(status) else { return nil }
            defer {
                data.removeAll(keepingCapacity: true)
                // Running status applies to channel messages only.
                if status >= 0xF0 { self.status = nil }
            }
            return message(status: status, data: data)
        }
    }

    private func message(status: UInt8, data: [UInt8]) -> MIDIMessage? {
        let channel = status & 0x0F
        switch status & 0xF0 {
        case 0x90:
            return data[1] == 0 ? .noteOff(channel: channel, note: data[0]) : .noteOn(channel: channel, note: data[0], velocity: data[1])
        case 0x80:
            return .noteOff(channel: channel, note: data[0])
        default:
            return status == 0xF1 ? .quarterFrame(data[0]) : nil
        }
    }

    private static func dataLength(_ status: UInt8) -> Int {
        switch status {
        case 0xC0...0xDF, 0xF1, 0xF3: return 1
        case 0xF2: return 2
        case 0xF4, 0xF5: return 0 // undefined; nothing follows
        default: return 2
        }
    }
}
