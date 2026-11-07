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
    /// A Song fired because the Playhead entered it. Its sends follow, unless disarmed.
    case fired(SongID)
    /// Send this Action now. Sends come in the order they must go out.
    case send(OutgoingAction)
    /// An Action could not be sent because its Destination no longer exists.
    case missingDestination(song: SongID, action: ActionID)
    /// The Armed state changed.
    case armedChanged(Bool)
}

/// An Action ready to send, with its Destination resolved.
public struct OutgoingAction: Hashable, Sendable {
    /// Why the Action is being sent.
    public enum Reason: Hashable, Sendable {
        case entering
    }

    public var songID: SongID
    public var action: Action
    public var destination: Destination
    public var reason: Reason

    public init(songID: SongID, action: Action, destination: Destination, reason: Reason) {
        self.songID = songID
        self.action = action
        self.destination = destination
        self.reason = reason
    }
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
    /// When disarmed, the engine follows timecode and tracks the current Song
    /// but sends nothing.
    public private(set) var isArmed: Bool

    private var lastReading: TimecodeReading?

    public init(set: ShowSet = ShowSet(), armed: Bool = false) {
        self.set = set
        self.isArmed = armed
    }

    public mutating func setArmed(_ armed: Bool) -> [EngineEvent] {
        guard armed != isArmed else { return [] }
        isArmed = armed
        return [.armedChanged(armed)]
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
                events += sends(for: songID, reason: .entering)
            }
        }

        return events
    }

    /// The sends for a Song's Start Actions, in list order. Nothing while disarmed.
    private func sends(for songID: SongID, reason: OutgoingAction.Reason) -> [EngineEvent] {
        guard isArmed, let song = set.songs.first(where: { $0.id == songID }) else { return [] }
        return song.startActions.map { action in
            guard let destination = set.destination(action.destinationID) else {
                return .missingDestination(song: songID, action: action.id)
            }
            return .send(OutgoingAction(songID: songID, action: action, destination: destination, reason: reason))
        }
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
