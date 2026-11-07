import TrigITProtocols

/// A stable random identifier for an entity of type `Tag`.
public struct EntityID<Tag>: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// A new random identifier.
    public init() {
        var generator = SystemRandomNumberGenerator()
        self.rawValue = generator.next()
    }

    public var description: String { "\(Tag.self)#\(rawValue)" }
}

public typealias SongID = EntityID<Song>
public typealias DestinationID = EntityID<Destination>
public typealias ActionID = EntityID<Action>
public typealias SetID = EntityID<ShowSet>

/// A MIDI note that triggers a Song: its Note On on this channel.
public struct NoteTrigger: Hashable, Sendable, Codable {
    /// 0...15 (shown to people as 1...16).
    public var channel: UInt8
    /// 0...127.
    public var note: UInt8

    public init(channel: UInt8, note: UInt8) {
        self.channel = min(channel, 15)
        self.note = min(note, 127)
    }

    /// "Ch 1 C3", naming notes as Ableton does.
    public var description: String {
        "Ch \(channel + 1) \(MIDINote(channel: channel, note: note).noteName)"
    }
}

/// One piece of music in the Set and the Actions it sends. It is triggered by
/// any combination of a span of timecode from `start` to `end` (both
/// inclusive), a Start Note and a Stop Note, and needs at least one of them.
/// Timecode between Songs belongs to no Song.
public struct Song: Identifiable, Hashable, Sendable {
    public var id: SongID
    public var name: String
    /// Whether the Song has a timecode span. Without one, `start` and `end`
    /// are kept (so the editor can switch the span back on) but ignored.
    public var hasSpan: Bool
    public var start: Timecode
    public var end: Timecode
    /// Its Note On makes the Song Enter.
    public var startNote: NoteTrigger?
    /// Its Note On makes the Song End if it is current, or, for a Song with
    /// only a Stop Note, sends its Stop Actions every time.
    public var stopNote: NoteTrigger?
    /// Sent, in order, on Entering.
    public var startActions: [Action]
    /// Sent, in order, on Ending. Usually empty; used for DJ pull-ups.
    public var stopActions: [Action]

    public init(id: SongID = SongID(), name: String, start: Timecode = .zero, end: Timecode = .zero,
                hasSpan: Bool = true, startNote: NoteTrigger? = nil, stopNote: NoteTrigger? = nil,
                startActions: [Action] = [], stopActions: [Action] = []) {
        self.id = id
        self.name = name
        self.hasSpan = hasSpan
        self.start = start
        self.end = end
        self.startNote = startNote
        self.stopNote = stopNote
        self.startActions = startActions
        self.stopActions = stopActions
    }

    /// Whether `position` lies inside this Song's span. A Song with no span,
    /// or whose end is before its start, contains nothing.
    public func contains(_ position: Timecode) -> Bool {
        hasSpan && start <= position && position <= end
    }

    /// Whether anything can trigger the Song: a span, a Start Note or a Stop Note.
    public var hasTrigger: Bool {
        hasSpan || startNote != nil || stopNote != nil
    }
}

/// A named device that Actions are sent to. It has a network address for
/// OSC and, optionally, a MIDI output for MIDI Actions; a grandMA3 may use both.
public struct Destination: Identifiable, Hashable, Sendable {
    public var id: DestinationID
    public var name: String
    /// IP address or host name.
    public var host: String
    public var port: UInt16
    /// The BSD name of the network interface to send through (for example
    /// "en1"), or nil to let macOS choose.
    public var networkInterface: String?
    /// The MIDI output for MIDI Actions, if any.
    public var midiOutput: MIDIPortReference?
    /// How DMX pulse Actions reach this Destination, if any. Uses `host` and
    /// `networkInterface`, but not `port`: Art-Net and sACN have fixed ports.
    public var dmxOutput: DMXOutput?

    public init(id: DestinationID = DestinationID(), name: String, host: String, port: UInt16,
                networkInterface: String? = nil, midiOutput: MIDIPortReference? = nil, dmxOutput: DMXOutput? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.networkInterface = networkInterface
        self.midiOutput = midiOutput
        self.dmxOutput = dmxOutput
    }
}

/// The DMX-over-network protocol a Destination receives pulses with.
public enum DMXOutput: String, Hashable, Sendable, Codable, CaseIterable {
    /// Art-Net to `host`: a node's own address, or a broadcast address such as 2.255.255.255.
    case artNet
    /// sACN to each universe's multicast group (239.255.x.y).
    case sACNMulticast
    /// sACN straight to `host`.
    case sACNUnicast

    public var name: String {
        switch self {
        case .artNet: return "Art-Net"
        case .sACNMulticast: return "sACN multicast"
        case .sACNUnicast: return "sACN unicast"
        }
    }

    /// Universe numbers this protocol can address.
    public var universeRange: ClosedRange<Int> {
        self == .artNet ? ArtDmxPacket.portAddressRange : SACNDataPacket.universeRange
    }
}

/// A MIDI port remembered by its Core MIDI unique ID, with its name so it can
/// be shown even while unplugged.
public struct MIDIPortReference: Hashable, Sendable, Codable {
    public var uniqueID: Int32
    public var name: String

    public init(uniqueID: Int32, name: String) {
        self.uniqueID = uniqueID
        self.name = name
    }
}

/// One outgoing message a Song sends to one Destination.
public struct Action: Identifiable, Hashable, Sendable {
    public enum Message: Hashable, Sendable {
        /// Sent over UDP to the Destination's address.
        case osc(OSCMessage)
        /// Note On, then Note Off, to the Destination's MIDI output.
        case midiNote(MIDINote)
        /// MIDI Show Control SysEx to the Destination's MIDI output.
        case msc(MSCCommand)
        /// A value on one DMX channel for a moment, over the Destination's Art-Net or sACN.
        case dmxPulse(DMXPulse)

        /// Whether it goes out over MIDI rather than the network.
        public var isMIDI: Bool {
            switch self {
            case .midiNote, .msc: return true
            case .osc, .dmxPulse: return false
            }
        }
    }

    public var id: ActionID
    public var destinationID: DestinationID
    public var message: Message

    public init(id: ActionID = ActionID(), destinationID: DestinationID, message: Message) {
        self.id = id
        self.destinationID = destinationID
        self.message = message
    }
}

/// The show: an ordered list of Songs and the Destinations they send to.
/// Called `ShowSet` in code because `Set` is taken by the Swift standard
/// library; everywhere else it is the "Set".
public struct ShowSet: Hashable, Sendable {
    /// Stays the same when the file is renamed, moved or copied, so the Set's
    /// previous versions follow it.
    public var id: SetID
    public var name: String
    public var songs: [Song]
    public var destinations: [Destination]
    /// Seconds of silence from the Timecode Source before it counts as a Stop.
    /// Always within `stopTimeRange`.
    public var stopTime: Double {
        didSet { stopTime = min(max(stopTime, Self.stopTimeRange.lowerBound), Self.stopTimeRange.upperBound) }
    }

    public static let defaultStopTime = 2.0
    public static let stopTimeRange = 0.5...30.0

    public init(id: SetID = SetID(), name: String = "Untitled Set", songs: [Song] = [], destinations: [Destination] = [],
                stopTime: Double = ShowSet.defaultStopTime) {
        self.id = id
        self.name = name
        self.songs = songs
        self.destinations = destinations
        self.stopTime = min(max(stopTime, Self.stopTimeRange.lowerBound), Self.stopTimeRange.upperBound)
    }

    /// The Song whose span contains `position`, if any. Editing never lets
    /// spans overlap (see `apply`); if a hand-made Set has overlaps anyway, the
    /// first match in list order wins.
    public func song(at position: Timecode) -> Song? {
        songs.first { $0.contains(position) }
    }

    public func destination(_ id: DestinationID) -> Destination? {
        destinations.first { $0.id == id }
    }

    /// Every universe some pulse Action uses, per Destination. These are
    /// streamed continuously so receivers never see the source disappear.
    public var dmxUniversesInUse: [DestinationID: Swift.Set<Int>] {
        var universes: [DestinationID: Swift.Set<Int>] = [:]
        for song in songs {
            for action in song.startActions + song.stopActions {
                if case .dmxPulse(let pulse) = action.message {
                    universes[action.destinationID, default: []].insert(pulse.universe)
                }
            }
        }
        return universes
    }

    /// Whether any Song has an Action sending to the Destination.
    public func isInUse(_ id: DestinationID) -> Bool {
        songs.contains { song in (song.startActions + song.stopActions).contains { $0.destinationID == id } }
    }
}
