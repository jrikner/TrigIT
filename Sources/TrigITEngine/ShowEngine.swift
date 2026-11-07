/// The kind of Timecode Source a reading came from.
public enum TimecodeSourceKind: String, Sendable, Codable, CaseIterable {
    case simulator
    case ltc
    case mtc
    case artNet
}

/// One timecode position received from a Timecode Source.
public struct TimecodeReading: Hashable, Sendable {
    public var timecode: Timecode
    public var frameRate: FrameRate
    public var source: TimecodeSourceKind
    /// Monotonic time of arrival, in seconds. Only differences matter.
    public var timestamp: Double

    public init(timecode: Timecode, frameRate: FrameRate, source: TimecodeSourceKind, timestamp: Double) {
        self.timecode = timecode
        self.frameRate = frameRate
        self.source = source
        self.timestamp = timestamp
    }
}

/// Something the Show Engine reports to the outside world.
public enum EngineEvent: Hashable, Sendable {
    /// The Playhead moved to a new position.
    case playheadMoved(Timecode)
    /// The incoming frame rate is new or changed.
    case frameRateChanged(FrameRate)
    /// The Playhead jumped instead of advancing naturally.
    case jumped(from: Timecode, to: Timecode)
    /// The Song containing the Playhead changed (nil: the Playhead is in no Song).
    case currentSongChanged(SongID?)
    /// A Song fired because the Playhead entered it.
    case fired(SongID)
}

/// The pure core of TrigIT: it follows timecode readings and decides when
/// Songs fire. It performs no I/O and reads no clock; all time comes in
/// through reading timestamps, so it is fully deterministic.
public struct ShowEngine: Sendable {
    /// How far, in frames, the Playhead may land from where natural playback
    /// would have put it before the move counts as a Jump.
    public static let jumpToleranceFrames = 5.0

    public private(set) var set: ShowSet
    public private(set) var playhead: Timecode?
    public private(set) var frameRate: FrameRate?
    public private(set) var currentSongID: SongID?

    private var lastReading: TimecodeReading?

    public init(set: ShowSet = ShowSet()) {
        self.set = set
    }

    /// Replaces the Set. Nothing fires here; the next reading applies the new
    /// Songs with the normal rules.
    public mutating func updateSet(_ newSet: ShowSet) {
        set = newSet
    }

    /// Feeds one timecode reading and returns what happened, in order.
    public mutating func handle(_ reading: TimecodeReading) -> [EngineEvent] {
        var events: [EngineEvent] = []

        if reading.frameRate != frameRate {
            frameRate = reading.frameRate
            events.append(.frameRateChanged(reading.frameRate))
        }

        if let previous = lastReading, isJump(from: previous, to: reading) {
            events.append(.jumped(from: previous.timecode, to: reading.timecode))
        }

        if reading.timecode != playhead {
            playhead = reading.timecode
            events.append(.playheadMoved(reading.timecode))
        }
        lastReading = reading

        // Entering: the Playhead arrives inside a Song from outside it, whether
        // by playing or by a Jump. Staying inside the same Song never fires again.
        let songID = set.song(at: reading.timecode)?.id
        if songID != currentSongID {
            currentSongID = songID
            events.append(.currentSongChanged(songID))
            if let songID {
                events.append(.fired(songID))
            }
        }

        return events
    }

    /// A Jump is any landing far from where natural playback from the previous
    /// reading would be by now.
    private func isJump(from previous: TimecodeReading, to reading: TimecodeReading) -> Bool {
        let rate = reading.frameRate
        let elapsed = max(0, reading.timestamp - previous.timestamp)
        let expected = Double(previous.timecode.frameIndex(at: rate)) + elapsed * rate.realFramesPerSecond
        let actual = Double(reading.timecode.frameIndex(at: rate))
        return abs(actual - expected) > Self.jumpToleranceFrames
    }
}
