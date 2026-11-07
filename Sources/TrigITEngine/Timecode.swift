import TrigITProtocols

/// The frame rates a Timecode Source can run at. Defined with the protocol
/// codecs, which detect it.
public typealias FrameRate = TrigITProtocols.FrameRate

/// A timecode position, hh:mm:ss:ff.
///
/// Timecodes order by their fields, so two positions compare correctly whatever
/// frame rate is running. A Set stores no frame rate, so Song times are plain
/// positions.
public struct Timecode: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let hours: Int
    public let minutes: Int
    public let seconds: Int
    public let frames: Int

    /// Highest frame number accepted when no frame rate is known (30 fps timecode).
    public static let maxFrames = 29

    public init?(hours: Int, minutes: Int, seconds: Int, frames: Int) {
        guard (0..<24).contains(hours), (0..<60).contains(minutes),
              (0..<60).contains(seconds), (0...Self.maxFrames).contains(frames)
        else { return nil }
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    /// Parses `hh:mm:ss:ff`. A `;` or `.` before the frames (drop-frame
    /// notation) is also accepted.
    public init?(_ text: String) {
        let parts = text.trimmingWhitespace().split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." }
        )
        guard parts.count == 4,
              parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isASCIIDigit) }),
              let h = Int(parts[0]), let m = Int(parts[1]),
              let s = Int(parts[2]), let f = Int(parts[3])
        else { return nil }
        self.init(hours: h, minutes: m, seconds: s, frames: f)
    }

    public static let zero = Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0)!

    public var description: String {
        "\(Self.pad(hours)):\(Self.pad(minutes)):\(Self.pad(seconds)):\(Self.pad(frames))"
    }

    public static func < (lhs: Timecode, rhs: Timecode) -> Bool {
        (lhs.hours, lhs.minutes, lhs.seconds, lhs.frames)
            < (rhs.hours, rhs.minutes, rhs.seconds, rhs.frames)
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

// MARK: - Frame counting

extension Timecode {
    /// The number of frames since 00:00:00:00 at `rate`. Drop-frame timecode
    /// skips frame numbers 0 and 1 at the start of every minute except each
    /// tenth minute, so its frame count is smaller than its field values suggest.
    public func frameIndex(at rate: FrameRate) -> Int {
        TimecodeFields(hours: hours, minutes: minutes, seconds: seconds, frames: frames).frameIndex(at: rate)
    }

    /// The timecode `index` frames after 00:00:00:00 at `rate`, wrapping at 24 hours.
    public init(frameIndex index: Int, rate: FrameRate) {
        self.init(TimecodeFields(frameIndex: index, rate: rate))!
    }

    /// The timecode with the same fields, if they are in range.
    public init?(_ fields: TimecodeFields) {
        self.init(hours: fields.hours, minutes: fields.minutes, seconds: fields.seconds, frames: fields.frames)
    }
}

// MARK: - Small string helpers (the engine avoids Foundation)

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

extension String {
    func trimmingWhitespace() -> String {
        String(drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }
}
