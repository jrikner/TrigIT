import TrigITProtocols

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

/// Which of the two Timecode Sources a reading came from: the Primary Source
/// the show follows while it is healthy, or the optional Backup Source.
public enum SourceRole: String, Hashable, Sendable, CaseIterable {
    case primary
    case backup
}

/// A timecode problem the operator must see.
public enum TimecodeAlert: Hashable, Sendable {
    /// The Primary Source is lost and the show is following the Backup Source.
    case primaryLostRunningOnBackup
    /// No Timecode Source is healthy, and timecode has not (yet) Stopped.
    case allTimecodeLost
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
    /// A Timecode Source started or stopped sending timecode.
    case sourceHealthChanged(SourceRole, healthy: Bool)
    /// The engine now follows this Timecode Source.
    case liveSourceChanged(SourceRole)
    /// The timecode alert changed (nil: the problem is resolved).
    case alertChanged(TimecodeAlert?)
}

/// Why a Song fired.
public enum FiringCause: Hashable, Sendable {
    /// The Playhead entered it.
    case entering
    /// Its Start Note arrived.
    case note
    /// The operator fired it by hand.
    case manual
}

/// Why a Song Ended.
public enum EndingCause: Hashable, Sendable {
    /// The Playhead played on past its end time.
    case playedPastEnd
    /// Its Stop Note arrived.
    case note
    /// The operator pressed Fire stop.
    case manual
}

/// An Action ready to send, with its Destination resolved.
public struct OutgoingAction: Hashable, Sendable {
    /// Why the Action is being sent.
    public enum Reason: Hashable, Sendable {
        /// A Start Action, because the Song Entered (by timecode or its Start Note).
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
    /// A Timecode Source with no reading for longer than this is lost.
    public static let sourceLossTime = 0.25

    public private(set) var set: ShowSet
    public private(set) var playhead: Timecode?
    public private(set) var frameRate: FrameRate?
    /// The Song most recently Entered, by timecode or by its Start Note, until
    /// it Ends or another Song Enters.
    public private(set) var currentSongID: SongID?
    /// The Song whose span contains the Playhead. Timecode Enters a Song only
    /// when this changes, so a Song a note made current is not fired again by
    /// timecode, and timecode outside every Song leaves it current.
    private var timecodeSongID: SongID?
    /// When disarmed, the engine follows timecode and tracks the current Song
    /// but sends nothing.
    public private(set) var isArmed: Bool

    /// True from a Stop until timecode comes back.
    public private(set) var isStopped = false
    /// Where timecode was at a Stop, until the next reading. The current Song
    /// stays current but is re-armed: timecode resuming inside it fires its
    /// Start Actions again.
    private var stoppedAt: Timecode?

    /// The Timecode Source being followed. It changes only when it is lost
    /// while the other is healthy, and returns to the Primary on a Stop.
    public private(set) var liveSource: SourceRole = .primary
    public private(set) var alert: TimecodeAlert?

    /// The last reading followed, from the live source.
    private var lastReading: TimecodeReading?
    /// The last reading from each source, followed or not.
    private var lastReadings: [SourceRole: TimecodeReading] = [:]
    private var healthySources: Swift.Set<SourceRole> = []
    /// When timecode last started arriving after silence or a Stop. A source
    /// only counts as lost once timecode has been flowing for `sourceLossTime`,
    /// so two sources resuming together a few ms apart never cause a switch.
    private var resumedAt: Double?

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

    /// Feeds one timecode reading from the Primary or Backup Source and
    /// returns what happened, in order. Only the live source moves the
    /// Playhead; if the live source is lost while this one is healthy, this one
    /// becomes live, carrying on from where the lost one was: no Stop, no
    /// Dropout and no re-firing.
    public mutating func handle(_ reading: TimecodeReading, from role: SourceRole = .primary) -> [EngineEvent] {
        var events: [EngineEvent] = []
        let previous = lastReadings[role]
        lastReadings[role] = reading
        if resumedAt == nil { resumedAt = reading.timestamp }

        if role != liveSource {
            guard isLost(liveSource, at: reading.timestamp) else {
                return events + updateHealth(at: reading.timestamp)
            }
            liveSource = role
            events.append(.liveSourceChanged(role))
            // If this source has been running all along, follow on from its own
            // last reading, so the switch is seamless.
            if let previous, reading.timestamp - previous.timestamp <= Self.sourceLossTime {
                lastReading = previous
            }
        }
        events += follow(reading)
        return events + updateHealth(at: reading.timestamp)
    }

    private mutating func follow(_ reading: TimecodeReading) -> [EngineEvent] {
        var events: [EngineEvent] = []

        if reading.frameRate != frameRate {
            frameRate = reading.frameRate
            events.append(.frameRateChanged(reading.frameRate))
        }

        var jumped = false
        let restarted = stoppedAt != nil
        // Resuming after a Stop somewhere other than where it stopped is a
        // relocation: like a Jump, it Ends nothing.
        let relocated = stoppedAt.map { stopped in
            abs(Double(stopped.frameIndex(at: reading.frameRate) - reading.timecode.frameIndex(at: reading.frameRate)))
                > Self.jumpToleranceFrames
        } ?? false
        stoppedAt = nil
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
        guard songID != timecodeSongID || (restarted && songID != nil) else { return events }
        let left = timecodeSongID
        timecodeSongID = songID
        // Only leaving the current Song matters; one a note displaced is gone already.
        let leftCurrent = left != nil && left == currentSongID

        // Leaving a Song by playing on past its end time Ends it, before the next
        // Song fires. A Jump out of a Song, or playing backwards out of it, does not.
        if leftCurrent, let left, !jumped, !relocated,
           let song = set.songs.first(where: { $0.id == left }), reading.timecode > song.end {
            events += end(left, cause: .playedPastEnd)
        }

        // Entering: the Playhead arrives inside a Song from outside it, whether
        // by playing or by a Jump. Staying inside the same Song never fires
        // again, nor does arriving in a Song its Start Note already made current.
        if let songID {
            guard songID != currentSongID || restarted else { return events }
            events += enter(songID, cause: .entering)
        } else if leftCurrent {
            currentSongID = nil
            events.append(.currentSongChanged(nil))
        }
        return events
    }

    private mutating func enter(_ songID: SongID, cause: FiringCause) -> [EngineEvent] {
        let changed: [EngineEvent] = songID == currentSongID ? [] : [.currentSongChanged(songID)]
        currentSongID = songID
        return changed + [.fired(songID, cause)]
            + sends(for: songID, \.startActions, reason: .entering)
    }

    /// Feeds one incoming MIDI message. A Note On that is some Song's Stop Note
    /// Ends that Song if it is current (or, for a Song with only a Stop Note,
    /// sends its Stop Actions every time); then a Note On that is some Song's
    /// Start Note makes it Enter unless it is already current. Note Off, and
    /// Note On with velocity 0, are ignored, as is everything else.
    public mutating func handleMIDI(_ message: MIDIMessage) -> [EngineEvent] {
        guard case .noteOn(let channel, let note, let velocity) = message, velocity > 0 else { return [] }
        let trigger = NoteTrigger(channel: channel, note: note)
        var events: [EngineEvent] = []
        for song in set.songs where song.stopNote == trigger {
            if !song.hasSpan && song.startNote == nil {
                events += end(song.id, cause: .note)
            } else if song.id == currentSongID {
                events += end(song.id, cause: .note)
                currentSongID = nil
                events.append(.currentSongChanged(nil))
            }
        }
        for song in set.songs where song.startNote == trigger && song.id != currentSongID {
            events += enter(song.id, cause: .note)
        }
        return events
    }

    /// Lets time pass with no reading. When the source has been silent for
    /// longer than the Set's Stop time, that is a Stop. A Stop is not an End:
    /// no Stop Actions are sent and the current Song stays current, but it is
    /// re-armed, so timecode resuming inside it fires its Start Actions again.
    public mutating func tick(at time: Double) -> [EngineEvent] {
        guard !isStopped, let last = lastReading, time - last.timestamp > set.stopTime else {
            return updateHealth(at: time)
        }
        isStopped = true
        // After a Stop, the next reading starts afresh: neither a Jump nor a Dropout.
        lastReading = nil
        resumedAt = nil
        stoppedAt = last.timecode
        var events: [EngineEvent] = [.stopped]
        // A Stop returns the show to the Primary Source.
        if liveSource != .primary {
            liveSource = .primary
            events.append(.liveSourceChanged(.primary))
        }
        return events + updateHealth(at: time)
    }

    private func isHealthy(_ role: SourceRole, at time: Double) -> Bool {
        lastReadings[role].map { time - $0.timestamp <= Self.sourceLossTime } ?? false
    }

    private func isLost(_ role: SourceRole, at time: Double) -> Bool {
        guard let resumedAt, time - resumedAt > Self.sourceLossTime else { return false }
        return !isHealthy(role, at: time)
    }

    /// Reports sources going healthy or lost, and the alert that follows.
    private mutating func updateHealth(at time: Double) -> [EngineEvent] {
        var events: [EngineEvent] = []
        for role in SourceRole.allCases {
            let healthy = isHealthy(role, at: time)
            guard healthy != healthySources.contains(role) else { continue }
            if healthy { healthySources.insert(role) } else { healthySources.remove(role) }
            events.append(.sourceHealthChanged(role, healthy: healthy))
        }
        let newAlert: TimecodeAlert?
        if healthySources.isEmpty {
            // Silence after a Stop, or before any timecode, is normal.
            newAlert = isStopped || resumedAt == nil ? nil : .allTimecodeLost
        } else if liveSource == .backup, !healthySources.contains(.primary) {
            newAlert = .primaryLostRunningOnBackup
        } else {
            newAlert = nil
        }
        if newAlert != alert {
            alert = newAlert
            events.append(.alertChanged(newAlert))
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
