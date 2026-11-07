// Editing rules for a Set: every timecode position belongs to at most one Song.

extension Song {
    /// Whether this Song's span shares at least one frame with `other`'s. Spans
    /// include both ends; a Song whose end is before its start has no span and
    /// overlaps nothing.
    public func overlaps(_ other: Song) -> Bool {
        start <= end && other.start <= other.end && start <= other.end && other.start <= end
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

        public var description: String {
            switch self {
            case .tooFewColumns(let count): return "needs name, start and end; found \(count) column\(count == 1 ? "" : "s")"
            case .emptyName: return "the name is empty"
            case .invalidStart(let text): return "start \"\(text)\" is not a timecode (hh:mm:ss:ff)"
            case .invalidEnd(let text): return "end \"\(text)\" is not a timecode (hh:mm:ss:ff)"
            case .endBeforeStart: return "end is before start"
            case .overlaps(let name): return "overlaps \"\(name)\""
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
    /// Adds Songs from CSV text with the columns name, start, end. Comma,
    /// semicolon and tab separators all work, as do quoted fields and a header
    /// row. Rows that are invalid or would overlap an existing Song (or an
    /// earlier row) are skipped and reported; the rest are added.
    @discardableResult
    public mutating func importSongs(csv text: String) -> SongImportReport {
        var report = SongImportReport()
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let separator = Self.detectSeparator(lines)
        var isFirstRow = true

        for (offset, line) in lines.enumerated() {
            let columns = Self.splitCSV(String(line), separator: separator)
            if columns.allSatisfy(\.isEmpty) { continue }
            defer { isFirstRow = false }
            let lineNumber = offset + 1
            func problem(_ reason: SongImportReport.Reason) {
                report.problems.append(.init(line: lineNumber, reason: reason))
            }

            guard columns.count >= 3 else {
                problem(.tooFewColumns(columns.count))
                continue
            }
            let (name, startText, endText) = (columns[0], columns[1], columns[2])
            let start = Timecode(startText), end = Timecode(endText)
            // A first row whose times are both not timecodes is a header.
            if isFirstRow, start == nil, end == nil { continue }
            guard !name.isEmpty else { problem(.emptyName); continue }
            guard let start else { problem(.invalidStart(startText)); continue }
            guard let end else { problem(.invalidEnd(endText)); continue }
            guard start <= end else { problem(.endBeforeStart); continue }

            let song = Song(name: name, start: start, end: end)
            if let conflict = apply(song).first {
                problem(.overlaps(conflict.name))
            } else {
                report.imported.append(song)
            }
        }
        return report
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
