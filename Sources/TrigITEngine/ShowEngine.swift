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
    /// A Song fired: its Start Actions' sends follow (unless disarmed and automatic).
    case fired(SongID, FiringCause)
    /// A Song Ended: its Stop Actions' sends follow (unless disarmed and automatic).
    case ended(SongID, EndingCause)
    /// Timecode stopped: silence on the source for longer than the Set's Stop time.
    case stopped
    /// Timecode came back after a gap shorter than the Stop time. It never
    /// re-fires a Song.
    case dropout(seconds: Double)
    /// Send this Action now. Sends come in the order they must go out.
    case send(OutgoingAction)
    /// An Action could not be sent because its Destination no longer exists.
    case missingDestination(song: SongID, action: ActionID)
    /// The Armed state changed.
    case armedChanged(Bool)
}

/// Why a Song fired.
public enum FiringCause: Hashable, Sendable {
    /// The Playhead entered it.
    case entering
    /// The operator fired it by hand.
    case manual
}

/// Why a Song Ended.
public enum EndingCause: Hashable, Sendable {
    /// Timecode stopped while the Playhead was inside it.
    case stop
    /// The Playhead played on past its end time.
    case playedPastEnd
    /// The operator pressed Fire stop.
    case manual
}

/// An Action ready to send, with its Destination resolved.
public struct OutgoingAction: Hashable, Sendable {
    /// Why the Action is being sent.
    public enum Reason: Hashable, Sendable {
        /// A Start Action, because the Playhead entered the Song.
        case entering
        /// A Stop Action, because the Song Ended.
        case ending
        /// A Start Action fired by hand.
        case manualFire
        /// A Stop Action fired by hand.
        case manualStop
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
/// Songs fire and End. It performs no I/O and reads no clock; time comes in
/// through reading timestamps and `tick(at:)`, so it is fully deterministic.
public struct ShowEngine: Sendable {
    /// How far, in frames, the Playhead may land from where natural playback
    /// would have put it before the move counts as a Jump.
    public static let jumpToleranceFrames = 5.0
    /// A gap in timecode longer than this (but shorter than the Stop time) is
    /// reported as a Dropout. Shorter gaps are ordinary jitter.
    public static let dropoutThreshold = 0.2

    public private(set) var set: ShowSet
    public private(set) var playhead: Timecode?
    public private(set) var frameRate: FrameRate?
    public private(set) var currentSongID: SongID?
    /// When disarmed, the engine follows timecode and tracks the current Song
    /// but sends nothing.
    public private(set) var isArmed: Bool

    /// True from a Stop until timecode comes back.
    public private(set) var isStopped = false

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

        var jumped = false
        if let previous = lastReading {
            let gap = reading.timestamp - previous.timestamp
            if gap > Self.dropoutThreshold {
                events.append(.dropout(seconds: gap))
            }
            if isJump(from: previous, to: reading) {
                jumped = true
                events.append(.jumped(from: previous.timecode, to: reading.timecode))
            }
        }
        isStopped = false

        if reading.timecode != playhead {
            playhead = reading.timecode
            events.append(.playheadMoved(reading.timecode))
        }
        lastReading = reading

        let songID = set.song(at: reading.timecode)?.id
        guard songID != currentSongID else { return events }

        // Leaving a Song by playing on past its end time Ends it, before the next
        // Song fires. A Jump out of a Song, or playing backwards out of it, does not.
        if let current = currentSongID, !jumped,
           let song = set.songs.first(where: { $0.id == current }), reading.timecode > song.end {
            events += end(current, cause: .playedPastEnd)
        }

        // Entering: the Playhead arrives inside a Song from outside it, whether
        // by playing or by a Jump. Staying inside the same Song never fires again.
        currentSongID = songID
        events.append(.currentSongChanged(songID))
        if let songID {
            events.append(.fired(songID, .entering))
            events += sends(for: songID, \.startActions, reason: .entering)
        }
        return events
    }

    /// Lets time pass with no reading. When the source has been silent for
    /// longer than the Set's Stop time, that is a Stop: the current Song Ends
    /// and is re-armed, so timecode resuming inside it fires it again.
    public mutating func tick(at time: Double) -> [EngineEvent] {
        guard !isStopped, let last = lastReading, time - last.timestamp > set.stopTime else { return [] }
        isStopped = true
        // After a Stop, the next reading starts afresh: neither a Jump nor a Dropout.
        lastReading = nil
        var events: [EngineEvent] = [.stopped]
        if let current = currentSongID {
            events += end(current, cause: .stop)
            currentSongID = nil
            events.append(.currentSongChanged(nil))
        }
        return events
    }

    /// Fires a Song's Start Actions by hand. Sends even while disarmed: this is
    /// the operator's fallback. The current Song is not changed.
    public func fire(_ songID: SongID) -> [EngineEvent] {
        guard set.songs.contains(where: { $0.id == songID }) else { return [] }
        return [.fired(songID, .manual)] + sends(for: songID, \.startActions, reason: .manualFire, evenIfDisarmed: true)
    }

    /// Sends a Song's Stop Actions by hand, even while disarmed.
    public func fireStop(_ songID: SongID) -> [EngineEvent] {
        guard set.songs.contains(where: { $0.id == songID }) else { return [] }
        return [.ended(songID, .manual)] + sends(for: songID, \.stopActions, reason: .manualStop, evenIfDisarmed: true)
    }

    private func end(_ songID: SongID, cause: EndingCause) -> [EngineEvent] {
        [.ended(songID, cause)] + sends(for: songID, \.stopActions, reason: .ending)
    }

    /// The sends for one of a Song's Action lists, in list order. Automatic
    /// sends are suppressed while disarmed.
    private func sends(for songID: SongID, _ list: KeyPath<Song, [Action]>, reason: OutgoingAction.Reason,
                       evenIfDisarmed: Bool = false) -> [EngineEvent] {
        guard isArmed || evenIfDisarmed, let song = set.songs.first(where: { $0.id == songID }) else { return [] }
        return song[keyPath: list].map { action in
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
