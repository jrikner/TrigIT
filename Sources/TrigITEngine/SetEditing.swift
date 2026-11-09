// SPDX-License-Identifier: GPL-3.0-or-later

import TrigITProtocols

// Editing rules for a Set: every timecode position belongs to at most one Song.

extension Song {
    /// Whether this Song's span shares at least one frame with `other`'s. Spans
    /// include both ends; a Song with no span, or whose end is before its
    /// start, overlaps nothing.
    public func overlaps(_ other: Song) -> Bool {
        hasSpan && other.hasSpan && start <= end && other.start <= other.end && start <= other.end && other.start <= end
    }
}

extension ShowSet {
    /// The other Songs whose spans overlap `song` (matched by ID, so an edited
    /// copy of a Song never conflicts with itself).
    public func songsOverlapping(_ song: Song) -> [Song] {
        songs.filter { $0.id != song.id && $0.overlaps(song) }
    }

    /// Replaces the Song with the same ID, or appends it if new, unless that
    /// would make it overlap another Song. Returns the Songs in the way; empty
    /// means the edit was applied.
    @discardableResult
    public mutating func apply(_ song: Song) -> [Song] {
        let conflicts = songsOverlapping(song)
        guard conflicts.isEmpty else { return conflicts }
        if let index = songs.firstIndex(where: { $0.id == song.id }) {
            songs[index] = song
        } else {
            songs.append(song)
        }
        return []
    }
}

// MARK: - Note Clashes

/// Songs whose Start or Stop Notes would trigger together on one Note On.
/// Warned about in Edit but allowed, since a Song may be mid-way through
/// swapping notes with another.
public struct NoteClash: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Two or more Songs share this Start Note: all of them Enter.
        case startNote
        /// Two or more Songs share this Stop Note.
        case stopNote
        /// One Song's Start Note is its own Stop Note: it Ends and Enters again.
        case startIsStop
    }

    public var kind: Kind
    public var note: NoteTrigger
    /// In Set order; one Song for `.startIsStop`.
    public var songs: [SongID]

    public init(kind: Kind, note: NoteTrigger, songs: [SongID]) {
        self.kind = kind
        self.note = note
        self.songs = songs
    }
}

extension ShowSet {
    /// Every Note Clash in the Set. One Song's Stop Note being another's
    /// Start Note is a hand-off, not a clash.
    public var noteClashes: [NoteClash] {
        func shared(_ kind: NoteClash.Kind, _ note: (Song) -> NoteTrigger?) -> [NoteClash] {
            var order: [NoteTrigger] = []
            var songsByNote: [NoteTrigger: [SongID]] = [:]
            for song in songs {
                guard let trigger = note(song) else { continue }
                if songsByNote[trigger] == nil { order.append(trigger) }
                songsByNote[trigger, default: []].append(song.id)
            }
            return order.compactMap { trigger in
                let ids = songsByNote[trigger]!
                return ids.count > 1 ? NoteClash(kind: kind, note: trigger, songs: ids) : nil
            }
        }
        let own = songs.compactMap { song in
            song.startNote.flatMap { $0 == song.stopNote ? NoteClash(kind: .startIsStop, note: $0, songs: [song.id]) : nil }
        }
        return shared(.startNote, \.startNote) + shared(.stopNote, \.stopNote) + own
    }
}

// MARK: - CSV import

/// What happened when Songs were imported from CSV.
public struct SongImportReport: Hashable, Sendable {
    public struct Problem: Hashable, Sendable {
        /// 1-based line number in the file.
        public var line: Int
        public var reason: Reason

        public init(line: Int, reason: Reason) {
            self.line = line
            self.reason = reason
        }
    }

    public enum Reason: Hashable, Sendable, CustomStringConvertible {
        case tooFewColumns(Int)
        case emptyName
        case invalidStart(String)
        case invalidEnd(String)
        case endBeforeStart
        case overlaps(String)
        // An Action row (columns 4-8) that adds no Action.
        case noSongAbove
        case songAboveSkipped
        case actionWithoutDestination
        case invalidWhen(String)
        case invalidKind(String)
        case invalidOSCAddress(String)
        case unterminatedArguments(String)
        case invalidNote(String)
        case invalidVelocity(String)
        case invalidUniverseChannel(String)
        case invalidDMXValue(String)

        /// Worded as the MA3 plugin words it (ma3-plugin/src/trigit_plan.lua).
        public var description: String {
            switch self {
            case .tooFewColumns(let count): return "needs name, start and end; found \(count) column\(count == 1 ? "" : "s")"
            case .emptyName: return "the name is empty"
            case .invalidStart(let text): return "start \"\(text)\" is not a timecode (hh:mm:ss:ff)"
            case .invalidEnd(let text): return "end \"\(text)\" is not a timecode (hh:mm:ss:ff)"
            case .endBeforeStart: return "end is before start"
            case .overlaps(let name): return "overlaps \"\(name)\""
            case .noSongAbove: return "no Song above to add the Action to"
            case .songAboveSkipped: return "the Song above was skipped"
            case .actionWithoutDestination: return "the Action has no destination"
            case .invalidWhen(let text): return "when \"\(text)\" is not start or stop"
            case .invalidKind(let text): return "kind \"\(text)\" is not osc, midi-note or dmx"
            case .invalidOSCAddress(let text): return "\"\(text)\" is not an OSC address"
            case .unterminatedArguments(let text): return "arguments \"\(text)\" have an unterminated quote"
            case .invalidNote(let text): return "note \"\(text)\" is not a note (60, or channel/note as 10/36)"
            case .invalidVelocity(let text): return "velocity \"\(text)\" is not 1-127"
            case .invalidUniverseChannel(let text): return "\"\(text)\" is not universe.channel (channel 1-512)"
            case .invalidDMXValue(let text): return "value \"\(text)\" is not 0-255"
            }
        }
    }

    public var imported: [Song] = []
    public var problems: [Problem] = []

    public init(imported: [Song] = [], problems: [Problem] = []) {
        self.imported = imported
        self.problems = problems
    }
}

extension ShowSet {
    /// Adds Songs from CSV text with the columns name, start, end, and
    /// optionally an Action in destination, kind, address, args/value, when.
    /// A row with no name, start or end adds another Action to the Song above.
    /// The format and its rules are the MA3 plugin's (ma3-plugin/README.md).
    /// Comma, semicolon and tab separators all work, as do quoted fields and a
    /// header row. Rows that are invalid or would overlap an existing Song (or
    /// an earlier row) are skipped and reported; a bad Action row loses only
    /// that Action. Destinations are found by name, or added, and get the
    /// transports their Actions need.
    @discardableResult
    public mutating func importSongs(csv text: String) -> SongImportReport {
        var report = SongImportReport()
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let separator = Self.detectSeparator(lines)
        var isFirstRow = true

        /// The Song above: none yet, a skipped row, or one being read.
        enum Above { case none, skipped, song(Song, line: Int, actions: [(CSVAction, Action.Message)]) }
        var above = Above.none

        func problem(_ line: Int, _ reason: SongImportReport.Reason) {
            report.problems.append(.init(line: line, reason: reason))
        }
        func flush() {
            guard case .song(var song, let line, let actions) = above else { return }
            if let conflict = songsOverlapping(song).first {
                problem(line, .overlaps(conflict.name))
                return
            }
            for (action, message) in actions {
                let destinationID = destinationID(named: action.destination, carrying: message)
                let item = Action(destinationID: destinationID, message: message)
                if action.isStop { song.stopActions.append(item) } else { song.startActions.append(item) }
            }
            apply(song)
            report.imported.append(song)
        }
        func addAction(_ columns: [String], line: Int) {
            switch Self.parseAction(columns) {
            case .none: break
            case .failure(let reason): problem(line, reason)
            case .success(let action, let message):
                if case .song(let song, let songLine, var actions) = above {
                    actions.append((action, message))
                    above = .song(song, line: songLine, actions: actions)
                }
            }
        }

        for (offset, line) in lines.enumerated() {
            let columns = Self.splitCSV(String(line), separator: separator)
            if columns.allSatisfy(\.isEmpty) { continue }
            let firstRow = isFirstRow
            isFirstRow = false
            let lineNumber = offset + 1

            guard columns.count >= 3 else {
                flush()
                above = .skipped
                problem(lineNumber, .tooFewColumns(columns.count))
                continue
            }
            let (name, startText, endText) = (columns[0], columns[1], columns[2])
            if name.isEmpty, startText.isEmpty, endText.isEmpty {
                switch above {
                case .song: addAction(columns, line: lineNumber)
                case .none: problem(lineNumber, .noSongAbove)
                case .skipped: problem(lineNumber, .songAboveSkipped)
                }
                continue
            }
            let start = Timecode(startText), end = Timecode(endText)
            // A first row whose times are both not timecodes is a header.
            if firstRow, start == nil, end == nil { continue }
            flush()
            above = .skipped
            guard !name.isEmpty else { problem(lineNumber, .emptyName); continue }
            guard let start else { problem(lineNumber, .invalidStart(startText)); continue }
            guard let end else { problem(lineNumber, .invalidEnd(endText)); continue }
            guard start <= end else { problem(lineNumber, .endBeforeStart); continue }
            above = .song(Song(name: name, start: start, end: end), line: lineNumber, actions: [])
            addAction(columns, line: lineNumber)
        }
        flush()
        // In line order: overlaps are found once a Song's Action rows are read.
        report.problems = report.problems.enumerated()
            .sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
            .map(\.element)
        return report
    }

    /// The Destination with this name, with the message's transport switched
    /// on, added if there is none.
    private mutating func destinationID(named name: String, carrying message: Action.Message) -> DestinationID {
        let index = destinations.firstIndex { $0.name == name } ?? {
            destinations.append(Destination(name: name, host: "", port: 0, usesOSC: false, usesMIDI: false, usesDMX: false))
            return destinations.count - 1
        }()
        destinations[index][uses: message.transport] = true
        return destinations[index].id
    }

    /// One Action read from columns 4-8.
    struct CSVAction {
        var destination: String
        var isStop: Bool
    }

    enum ParsedAction {
        case none
        case failure(SongImportReport.Reason)
        case success(CSVAction, Action.Message)
    }

    /// The Action in columns 4-8, by the MA3 plugin's rules (`parseAction` in
    /// ma3-plugin/src/trigit_plan.lua).
    static func parseAction(_ columns: [String]) -> ParsedAction {
        func column(_ index: Int) -> String { index < columns.count ? columns[index] : "" }
        let (destination, kindText, target, value, whenText) = (column(3), column(4), column(5), column(6), column(7))
        if (destination + kindText + target + value + whenText).isEmpty { return .none }
        guard !destination.isEmpty else { return .failure(.actionWithoutDestination) }
        let when = whenText.lowercased()
        guard ["", "start", "stop"].contains(when) else { return .failure(.invalidWhen(whenText)) }
        let action = CSVAction(destination: destination, isStop: when == "stop")

        /// Digits only, within the range.
        func integer(_ text: Substring, in range: ClosedRange<Int>) -> Int? {
            guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), let value = Int(text),
                  range.contains(value) else { return nil }
            return value
        }

        switch kindText.lowercased() {
        case "osc":
            let message = OSCMessage(address: target)
            guard message.hasValidAddress else { return .failure(.invalidOSCAddress(target)) }
            guard let arguments = OSCArgument.parseList(value) else { return .failure(.unterminatedArguments(value)) }
            return .success(action, .osc(OSCMessage(address: target, arguments: arguments)))
        case "midi-note":
            let parts = target.split(separator: "/", omittingEmptySubsequences: false)
            let channel = parts.count == 2 ? integer(parts[0], in: 1...16) : 1
            let note = parts.count <= 2 ? integer(parts[parts.count - 1], in: 0...127) : nil
            guard let channel, let note else { return .failure(.invalidNote(target)) }
            guard let velocity = value.isEmpty ? 127 : integer(Substring(value), in: 1...127) else {
                return .failure(.invalidVelocity(value))
            }
            return .success(action, .midiNote(MIDINote(channel: UInt8(channel - 1), note: UInt8(note), velocity: UInt8(velocity))))
        case "dmx":
            let parts = target.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, let universe = integer(parts[0], in: 0...63_999),
                  let channel = integer(parts[1], in: 1...dmxSlotCount) else {
                return .failure(.invalidUniverseChannel(target))
            }
            guard let level = value.isEmpty ? 255 : integer(Substring(value), in: 0...255) else {
                return .failure(.invalidDMXValue(value))
            }
            return .success(action, .dmxPulse(DMXPulse(universe: universe, channel: channel, value: UInt8(level))))
        default:
            return .failure(.invalidKind(kindText))
        }
    }

    /// The separator used most on the first non-empty line, outside quotes.
    private static func detectSeparator(_ lines: [Substring]) -> Character {
        guard let first = lines.first(where: { !$0.allSatisfy(\.isWhitespace) }) else { return "," }
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for character in first {
            if character == "\"" { inQuotes.toggle() }
            if !inQuotes, counts[character] != nil { counts[character]! += 1 }
        }
        return [",", ";", "\t"].max { counts[$0]! < counts[$1]! } ?? ","
    }

    /// Splits one CSV line into trimmed fields. Quoted fields may contain the
    /// separator, and "" inside quotes is a literal quote.
    private static func splitCSV(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var characters = line.makeIterator()
        var pending = characters.next()
        while let character = pending {
            pending = characters.next()
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = characters.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == separator {
                fields.append(field.trimmingWhitespace())
                field = ""
            } else {
                field.append(character)
            }
        }
        fields.append(field.trimmingWhitespace())
        return fields
    }
}
