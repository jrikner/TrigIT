// SPDX-License-Identifier: GPL-3.0-or-later

/// A timecode position decoded from MIDI Time Code.
public struct MTCTime: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Assembled from quarter-frame messages while running.
        case quarterFrame
        /// A full-frame SysEx message: sent when the transport locates (a Jump)
        /// or while it is parked.
        case fullFrame
    }

    public var fields: TimecodeFields
    public var frameRate: FrameRate
    public var kind: Kind
    /// Quarter-frames are arriving in reverse order: playing backwards.
    public var isReverse: Bool

    public init(fields: TimecodeFields, frameRate: FrameRate, kind: Kind, isReverse: Bool = false) {
        self.fields = fields
        self.frameRate = frameRate
        self.kind = kind
        self.isReverse = isReverse
    }
}

/// Decodes MIDI Time Code from parsed MIDI messages.
///
/// Running MTC sends four quarter-frame messages per frame, so a whole time
/// takes eight messages over two frames. The time they spell out is the frame
/// in which the first piece was sent; by the time the last arrives the
/// transport is two frames further on, so the decoder reports that. Halfway
/// through the next set it also reports one frame later, so the Playhead moves
/// every frame rather than every second frame.
public struct MTCDecoder: Sendable {
    private var pieces = [UInt8](repeating: 0, count: 8)
    private var received: UInt8 = 0
    private var lastPiece: Int?
    /// Unknown until two pieces have arrived.
    private var direction: Direction?
    private var isReverse: Bool { direction == .reverse }

    private enum Direction { case forward, reverse }
    /// The last time reported from quarter-frames, while they keep arriving in sequence.
    private var lastReported: MTCTime?

    public init() {}

    /// Returns the time this message completes, if any.
    public mutating func receive(_ message: MIDIMessage) -> MTCTime? {
        switch message {
        case .quarterFrame(let byte):
            return quarterFrame(piece: Int(byte >> 4) & 0x07, value: byte & 0x0F)
        case .systemExclusive(let bytes):
            return fullFrame(bytes)
        default:
            return nil
        }
    }

    private mutating func quarterFrame(piece: Int, value: UInt8) -> MTCTime? {
        if let last = lastPiece {
            let step: Direction? = piece == (last + 1) % 8 ? .forward : piece == (last + 7) % 8 ? .reverse : nil
            if step == nil || (direction != nil && step != direction) {
                restart() // a piece went missing, the transport jumped, or it changed direction
            }
            direction = step
        }
        lastPiece = piece
        pieces[piece] = value
        received |= 1 << piece

        // A set completes on piece 7 going forwards, or piece 0 going backwards.
        guard let direction else { return nil }
        let finalPiece = direction == .reverse ? 0 : 7
        if piece == finalPiece {
            defer { received = 0 }
            guard received == 0xFF, let time = assembled() else {
                lastReported = nil
                return nil
            }
            let reported = MTCTime(fields: time.fields.advanced(by: isReverse ? -2 : 2, rate: time.frameRate),
                                   frameRate: time.frameRate, kind: .quarterFrame, isReverse: isReverse)
            lastReported = reported
            return reported
        }

        // Halfway through the next set: one frame on from the last report.
        let midpoint = isReverse ? 4 : 3
        if piece == midpoint, let last = lastReported {
            let next = MTCTime(fields: last.fields.advanced(by: isReverse ? -1 : 1, rate: last.frameRate),
                               frameRate: last.frameRate, kind: .quarterFrame, isReverse: isReverse)
            return next
        }
        return nil
    }

    private mutating func restart() {
        received = 0
        lastReported = nil
    }

    private func assembled() -> MTCTime? {
        let rate = Self.rate(code: pieces[7] >> 1 & 0x03)
        let fields = TimecodeFields(
            hours: Int(pieces[7] & 0x01) << 4 | Int(pieces[6]),
            minutes: Int(pieces[5] & 0x03) << 4 | Int(pieces[4]),
            seconds: Int(pieces[3] & 0x03) << 4 | Int(pieces[2]),
            frames: Int(pieces[1] & 0x01) << 4 | Int(pieces[0])
        )
        guard fields.isValid(at: rate) else { return nil }
        return MTCTime(fields: fields, frameRate: rate, kind: .quarterFrame, isReverse: isReverse)
    }

    /// F0 7F <device> 01 01 hr mn sc fr F7, where hr is 0rrhhhhh.
    private mutating func fullFrame(_ bytes: [UInt8]) -> MTCTime? {
        guard bytes.count == 10, bytes[0] == 0xF0, bytes[1] == 0x7F, bytes[3] == 0x01, bytes[4] == 0x01,
              bytes[9] == 0xF7 else { return nil }
        let rate = Self.rate(code: bytes[5] >> 5 & 0x03)
        let fields = TimecodeFields(hours: Int(bytes[5] & 0x1F), minutes: Int(bytes[6]),
                                    seconds: Int(bytes[7]), frames: Int(bytes[8]))
        guard fields.isValid(at: rate) else { return nil }
        // Quarter-frames that follow start a fresh set.
        lastPiece = nil
        direction = nil
        restart()
        return MTCTime(fields: fields, frameRate: rate, kind: .fullFrame)
    }

    private static func rate(code: UInt8) -> FrameRate {
        switch code {
        case 0: return .fps24
        case 1: return .fps25
        case 2: return .fps2997DropFrame
        default: return .fps30
        }
    }
}

/// Encodes MTC, for tests and simulators: the eight quarter-frame data bytes
/// for a time, and the full-frame SysEx.
public enum MTCEncoder {
    public static func quarterFrames(_ fields: TimecodeFields, rate: FrameRate) -> [UInt8] {
        let rateCode = code(for: rate)
        let values: [UInt8] = [
            UInt8(fields.frames & 0x0F), UInt8(fields.frames >> 4 & 0x01),
            UInt8(fields.seconds & 0x0F), UInt8(fields.seconds >> 4 & 0x03),
            UInt8(fields.minutes & 0x0F), UInt8(fields.minutes >> 4 & 0x03),
            UInt8(fields.hours & 0x0F), UInt8(fields.hours >> 4 & 0x01) | rateCode << 1,
        ]
        return values.enumerated().map { UInt8($0.offset) << 4 | $0.element }
    }

    public static func fullFrame(_ fields: TimecodeFields, rate: FrameRate, device: UInt8 = 0x7F) -> [UInt8] {
        let rateCode = code(for: rate)
        return [0xF0, 0x7F, device, 0x01, 0x01, rateCode << 5 | UInt8(fields.hours),
                UInt8(fields.minutes), UInt8(fields.seconds), UInt8(fields.frames), 0xF7]
    }

    private static func code(for rate: FrameRate) -> UInt8 {
        switch rate {
        case .fps24: return 0
        case .fps25: return 1
        case .fps2997DropFrame: return 2
        case .fps30: return 3
        }
    }
}
