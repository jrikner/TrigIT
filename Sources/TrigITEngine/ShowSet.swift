import TrigITProtocols

/// A stable random identifier for an entity of type `Tag`.
public struct EntityID<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
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

/// One piece of music in the Set: a span of timecode from `start` to `end`,
/// both inclusive, and the Actions it sends. Timecode between Songs belongs to
/// no Song.
public struct Song: Identifiable, Hashable, Sendable, Codable {
    public var id: SongID
    public var name: String
    public var start: Timecode
    public var end: Timecode
    /// Sent, in order, on Entering.
    public var startActions: [Action]

    public init(id: SongID = SongID(), name: String, start: Timecode, end: Timecode, startActions: [Action] = []) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.startActions = startActions
    }

    /// Whether `position` lies inside this Song's span. A Song whose end is
    /// before its start contains nothing.
    public func contains(_ position: Timecode) -> Bool {
        start <= position && position <= end
    }
}

/// A named device that Actions are sent to.
public struct Destination: Identifiable, Hashable, Sendable, Codable {
    public var id: DestinationID
    public var name: String
    /// IP address or host name.
    public var host: String
    public var port: UInt16
    /// The BSD name of the network interface to send through (for example
    /// "en1"), or nil to let macOS choose.
    public var networkInterface: String?

    public init(id: DestinationID = DestinationID(), name: String, host: String, port: UInt16, networkInterface: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.networkInterface = networkInterface
    }
}

/// One outgoing message a Song sends to one Destination.
public struct Action: Identifiable, Hashable, Sendable, Codable {
    public enum Message: Hashable, Sendable, Codable {
        case osc(OSCMessage)
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
public struct ShowSet: Hashable, Sendable, Codable {
    public var name: String
    public var songs: [Song]
    public var destinations: [Destination]

    public init(name: String = "Untitled Set", songs: [Song] = [], destinations: [Destination] = []) {
        self.name = name
        self.songs = songs
        self.destinations = destinations
    }

    /// The Song whose span contains `position`, if any. Overlapping Songs are
    /// blocked when editing (a later feature); until then the first match in
    /// list order wins.
    public func song(at position: Timecode) -> Song? {
        songs.first { $0.contains(position) }
    }

    public func destination(_ id: DestinationID) -> Destination? {
        destinations.first { $0.id == id }
    }

    /// Whether any Song has an Action sending to the Destination.
    public func isInUse(_ id: DestinationID) -> Bool {
        songs.contains { song in song.startActions.contains { $0.destinationID == id } }
    }
}
