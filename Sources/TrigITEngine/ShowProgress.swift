/// Where the Playhead is within the Set, for the Show screen: how far into the
/// current Song's span it is, and how long until the next Song starts.
public struct ShowProgress: Equatable, Sendable {
    /// Seconds since the current Song's start, and its span's length, if the
    /// Playhead is inside a Song's span.
    public var elapsed: Double?
    public var duration: Double?
    /// The next Song by start time after the Playhead, and the seconds until it starts.
    public var nextSongID: SongID?
    public var untilNext: Double?

    public init(set: ShowSet, playhead: Timecode, rate: FrameRate) {
        let seconds = { (timecode: Timecode) in Double(timecode.frameIndex(at: rate)) / rate.realFramesPerSecond }
        let now = seconds(playhead)
        if let current = set.songs.first(where: { $0.contains(playhead) }) {
            elapsed = now - seconds(current.start)
            duration = seconds(current.end) - seconds(current.start)
        }
        if let next = set.songs.filter({ $0.hasSpan && $0.start > playhead }).min(by: { $0.start < $1.start }) {
            nextSongID = next.id
            untilNext = seconds(next.start) - now
        }
    }
}

/// A one-line description of what changed between two versions of a Set, for
/// the Previous Versions list ("Moved the start of Intro, added an Action").
public enum SetChangeSummary {
    public static func describe(from old: ShowSet?, to new: ShowSet) -> String {
        guard let old else { return "Opened" }
        var parts: [String] = []
        let oldSongs = Dictionary(old.songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newIDs = Swift.Set(new.songs.map(\.id))
        let added = new.songs.filter { oldSongs[$0.id] == nil }
        let removed = old.songs.filter { !newIDs.contains($0.id) }
        if added.count == 1 { parts.append("added \(added[0].name)") }
        if added.count > 1 { parts.append("added \(added.count) Songs") }
        if removed.count == 1 { parts.append("deleted \(removed[0].name)") }
        if removed.count > 1 { parts.append("deleted \(removed.count) Songs") }

        var actionDelta = 0
        for song in new.songs {
            guard let before = oldSongs[song.id] else { continue }
            if before.name != song.name { parts.append("renamed \(before.name) to \(song.name)") }
            if before.start != song.start { parts.append("moved the start of \(song.name)") }
            if before.end != song.end { parts.append("moved the end of \(song.name)") }
            if before.startNote != song.startNote || before.stopNote != song.stopNote || before.hasSpan != song.hasSpan {
                parts.append("changed the triggers of \(song.name)")
            }
            let beforeActions = before.startActions + before.stopActions
            let actions = song.startActions + song.stopActions
            actionDelta += actions.count - beforeActions.count
            if actions.count == beforeActions.count, actions != beforeActions {
                parts.append("edited the Actions of \(song.name)")
            }
        }
        if actionDelta == 1 { parts.append("added an Action") }
        if actionDelta > 1 { parts.append("added \(actionDelta) Actions") }
        if actionDelta == -1 { parts.append("deleted an Action") }
        if actionDelta < -1 { parts.append("deleted \(-actionDelta) Actions") }
        if old.destinations != new.destinations { parts.append("changed Destinations") }
        if old.stopTime != new.stopTime { parts.append("changed the Stop time") }
        if old.name != new.name { parts.append("renamed the Set") }
        if parts.isEmpty { return "No changes" }
        // ponytail: lists every change; cap the length if long summaries get unreadable.
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
