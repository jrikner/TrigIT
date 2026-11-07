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

/// Frames in a 24-hour day at each rate, used to wrap positions.
private func framesPerDay(_ rate: FrameRate) -> Int {
    switch rate {
    case .fps2997DropFrame: return 24 * 6 * 17_982 // 2,589,408
    default: return 24 * 3_600 * rate.nominalFramesPerSecond
    }
}

extension Timecode {
    /// The number of frames since 00:00:00:00 at `rate`. Drop-frame timecode
    /// skips frame numbers 0 and 1 at the start of every minute except each
    /// tenth minute, so its frame count is smaller than its field values suggest.
    public func frameIndex(at rate: FrameRate) -> Int {
        let fps = rate.nominalFramesPerSecond
        let nominal = ((hours * 60 + minutes) * 60 + seconds) * fps + frames
        guard rate.isDropFrame else { return nominal }
        let totalMinutes = hours * 60 + minutes
        return nominal - 2 * (totalMinutes - totalMinutes / 10)
    }

    /// The timecode `index` frames after 00:00:00:00 at `rate`, wrapping at 24 hours.
    public init(frameIndex index: Int, rate: FrameRate) {
        let day = framesPerDay(rate)
        var n = ((index % day) + day) % day
        let fps = rate.nominalFramesPerSecond
        if rate.isDropFrame {
            // Add back the skipped frame numbers before splitting into fields.
            let tenMinuteBlocks = n / 17_982
            let remainder = n % 17_982
            n += 18 * tenMinuteBlocks + (remainder < 2 ? 0 : 2 * ((remainder - 2) / 1_798))
        }
        self.init(
            hours: n / (3_600 * fps),
            minutes: (n / (60 * fps)) % 60,
            seconds: (n / fps) % 60,
            frames: n % fps
        )!
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
