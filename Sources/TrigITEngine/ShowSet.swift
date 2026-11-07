/// One piece of music in the Set: a span of timecode from `start` to `end`,
/// both inclusive. Timecode between Songs belongs to no Song.
public struct Song: Identifiable, Hashable, Sendable, Codable {
    public typealias ID = SongID

    public var id: SongID
    public var name: String
    public var start: Timecode
    public var end: Timecode

    public init(id: SongID = SongID(), name: String, start: Timecode, end: Timecode) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
    }

    /// Whether `position` lies inside this Song's span. A Song whose end is
    /// before its start contains nothing.
    public func contains(_ position: Timecode) -> Bool {
        start <= position && position <= end
    }
}

/// Identifies a Song independently of its name and times.
public struct SongID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// A new random identifier.
    public init() {
        var generator = SystemRandomNumberGenerator()
        self.rawValue = generator.next()
    }

    public var description: String { "Song#\(rawValue)" }
}

/// The show: an ordered list of Songs. Called `ShowSet` in code because `Set`
/// is taken by the Swift standard library; everywhere else it is the "Set".
public struct ShowSet: Hashable, Sendable, Codable {
    public var name: String
    public var songs: [Song]

    public init(name: String = "Untitled Set", songs: [Song] = []) {
        self.name = name
        self.songs = songs
    }

    /// The Song whose span contains `position`, if any. Overlapping Songs are
    /// blocked when editing (a later feature); until then the first match in
    /// list order wins.
    public func song(at position: Timecode) -> Song? {
        songs.first { $0.contains(position) }
    }
}
