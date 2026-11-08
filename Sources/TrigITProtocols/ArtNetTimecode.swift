// SPDX-License-Identifier: GPL-3.0-or-later

/// Art-Net's UDP port.
public let artNetPort: UInt16 = 6454

/// An Art-Net 4 ArtTimeCode packet.
///
/// Layout (19 bytes): "Art-Net\0", OpCode 0x9700 (little-endian), protocol
/// version (big-endian, 14), Filler1, StreamId, Frames, Seconds, Minutes,
/// Hours, Type (0 Film 24, 1 EBU 25, 2 DF 29.97, 3 SMPTE 30).
public struct ArtTimeCode: Hashable, Sendable {
    public var fields: TimecodeFields
    public var frameRate: FrameRate
    /// Art-Net 4 stream ID (0 is the master stream).
    public var streamID: UInt8

    public init(fields: TimecodeFields, frameRate: FrameRate, streamID: UInt8 = 0) {
        self.fields = fields
        self.frameRate = frameRate
        self.streamID = streamID
    }

    static let header: [UInt8] = Array("Art-Net".utf8) + [0]
    static let opCode: UInt16 = 0x9700

    /// Parses a UDP payload; nil if it isn't a valid ArtTimeCode packet.
    public init?(packet bytes: [UInt8]) {
        guard bytes.count >= 19, Array(bytes[0..<8]) == Self.header,
              UInt16(bytes[8]) | UInt16(bytes[9]) << 8 == Self.opCode
        else { return nil }
        let rate: FrameRate
        switch bytes[18] {
        case 0: rate = .fps24
        case 1: rate = .fps25
        case 2: rate = .fps2997DropFrame
        case 3: rate = .fps30
        default: return nil
        }
        let fields = TimecodeFields(hours: Int(bytes[17]), minutes: Int(bytes[16]),
                                    seconds: Int(bytes[15]), frames: Int(bytes[14]))
        guard fields.isValid(at: rate) else { return nil }
        self.init(fields: fields, frameRate: rate, streamID: bytes[13])
    }

    /// The packet bytes, for tests and simulators.
    public var packet: [UInt8] {
        let type: UInt8
        switch frameRate {
        case .fps24: type = 0
        case .fps25: type = 1
        case .fps2997DropFrame: type = 2
        case .fps30: type = 3
        }
        return Self.header + [0x00, 0x97, 0x00, 14, 0x00, streamID,
                              UInt8(fields.frames), UInt8(fields.seconds), UInt8(fields.minutes), UInt8(fields.hours), type]
    }
}
