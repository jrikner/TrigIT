// SPDX-License-Identifier: GPL-3.0-or-later

/// The four fields of a timecode as a protocol carries them, with the frame
/// arithmetic the codecs need (drop-frame aware, wrapping at 24 hours).
public struct TimecodeFields: Hashable, Sendable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    /// Whether every field is in range for `rate`, including the frame
    /// numbers drop-frame timecode skips.
    public func isValid(at rate: FrameRate) -> Bool {
        guard (0..<24).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds),
              (0..<rate.nominalFramesPerSecond).contains(frames) else { return false }
        if rate.isDropFrame, seconds == 0, frames < 2, minutes % 10 != 0 { return false }
        return true
    }

    /// The number of frames since 00:00:00:00 at `rate`.
    public func frameIndex(at rate: FrameRate) -> Int {
        let fps = rate.nominalFramesPerSecond
        let nominal = ((hours * 60 + minutes) * 60 + seconds) * fps + frames
        guard rate.isDropFrame else { return nominal }
        let totalMinutes = hours * 60 + minutes
        return nominal - 2 * (totalMinutes - totalMinutes / 10)
    }

    /// The fields `index` frames after 00:00:00:00 at `rate`, wrapping at 24 hours.
    public init(frameIndex index: Int, rate: FrameRate) {
        let day = Self.framesPerDay(rate)
        var n = ((index % day) + day) % day
        let fps = rate.nominalFramesPerSecond
        if rate.isDropFrame {
            // Add back the skipped frame numbers before splitting into fields.
            let tenMinuteBlocks = n / 17_982
            let remainder = n % 17_982
            n += 18 * tenMinuteBlocks + (remainder < 2 ? 0 : 2 * ((remainder - 2) / 1_798))
        }
        self.init(hours: n / (3_600 * fps), minutes: (n / (60 * fps)) % 60, seconds: (n / fps) % 60, frames: n % fps)
    }

    /// The fields `count` frames later (or earlier, if negative).
    public func advanced(by count: Int, rate: FrameRate) -> TimecodeFields {
        TimecodeFields(frameIndex: frameIndex(at: rate) + count, rate: rate)
    }

    public var description: String {
        [hours, minutes, seconds, frames].map { $0 < 10 ? "0\($0)" : "\($0)" }.joined(separator: ":")
    }

    /// Frames in a 24-hour day at each rate.
    private static func framesPerDay(_ rate: FrameRate) -> Int {
        rate.isDropFrame ? 24 * 6 * 17_982 : 24 * 3_600 * rate.nominalFramesPerSecond
    }
}
