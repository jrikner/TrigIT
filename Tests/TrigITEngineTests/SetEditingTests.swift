// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import TrigITEngine

final class OverlapTests: XCTestCase {
    let intro = Song(id: SongID(rawValue: 1), name: "Intro", start: tc("01:00:00:00"), end: tc("01:04:00:00"))
    let anthem = Song(id: SongID(rawValue: 2), name: "Anthem", start: tc("02:00:00:00"), end: tc("02:05:00:00"))

    func song(_ start: String, _ end: String, id: UInt64 = 9) -> Song {
        Song(id: SongID(rawValue: id), name: "New", start: tc(start), end: tc(end))
    }

    func testSpansIncludeBothEnds() {
        XCTAssertTrue(intro.overlaps(song("01:04:00:00", "01:10:00:00")), "sharing the last frame")
        XCTAssertTrue(intro.overlaps(song("00:50:00:00", "01:00:00:00")), "sharing the first frame")
        XCTAssertFalse(intro.overlaps(song("01:04:00:01", "01:10:00:00")), "starting one frame after the end")
        XCTAssertFalse(intro.overlaps(song("00:50:00:00", "00:59:59:29")), "ending just before the start")
    }

    func testContainedAndContainingSpansOverlap() {
        XCTAssertTrue(intro.overlaps(song("01:01:00:00", "01:02:00:00")))
        XCTAssertTrue(intro.overlaps(song("00:30:00:00", "01:30:00:00")))
    }

    func testASongWithEndBeforeStartOverlapsNothing() {
        XCTAssertFalse(intro.overlaps(song("01:03:00:00", "01:01:00:00")))
        XCTAssertFalse(song("01:03:00:00", "01:01:00:00").overlaps(intro))
    }

    func testApplyRefusesAnOverlappingEditAndKeepsTheSet() {
        var set = ShowSet(songs: [intro, anthem])
        var moved = anthem
        moved.start = tc("01:03:00:00")
        XCTAssertEqual(set.apply(moved), [intro])
        XCTAssertEqual(set.songs, [intro, anthem])
    }

    func testApplyAcceptsAnEditThatOverlapsOnlyItsOldSelf() {
        var set = ShowSet(songs: [intro, anthem])
        var longer = intro
        longer.end = tc("01:30:00:00")
        XCTAssertEqual(set.apply(longer), [])
        XCTAssertEqual(set.songs, [longer, anthem])
    }

    func testMovingASongPastAnotherWorksStartFirst() {
        // Typing the new start first leaves end before start for a moment:
        // allowed, because such a Song has no span to overlap with.
        var set = ShowSet(songs: [intro, anthem])
        var moving = intro
        moving.start = tc("03:00:00:00")
        XCTAssertEqual(set.apply(moving), [])
        moving.end = tc("03:04:00:00")
        XCTAssertEqual(set.apply(moving), [])
        XCTAssertEqual(set.songs.map(\.start), [tc("03:00:00:00"), tc("02:00:00:00")])
    }

    func testApplyAppendsANewSong() {
        var set = ShowSet(songs: [intro])
        let new = song("05:00:00:00", "05:01:00:00")
        XCTAssertEqual(set.apply(new), [])
        XCTAssertEqual(set.songs, [intro, new])
    }
}

final class CSVImportTests: XCTestCase {
    func testImportsRowsWithAHeader() {
        var set = ShowSet()
        let report = set.importSongs(csv: """
            Name,Start,End
            Intro,01:00:00:00,01:04:00:00
            Anthem,02:00:00:00,02:05:30:12
            """)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(set.songs.map(\.name), ["Intro", "Anthem"])
        XCTAssertEqual(set.songs.map(\.end), [tc("01:04:00:00"), tc("02:05:30:12")])
        XCTAssertEqual(report.imported, set.songs)
    }

    func testImportsWithoutAHeader() {
        var set = ShowSet()
        set.importSongs(csv: "Intro,01:00:00:00,01:04:00:00\n")
        XCTAssertEqual(set.songs.map(\.name), ["Intro"])
    }

    func testAcceptsSemicolonsTabsQuotesAndWindowsLineEndings() {
        var semicolons = ShowSet()
        semicolons.importSongs(csv: "Name;Start;End\r\n\"Intro, part 1\";01:00:00:00;01:04:00:00\r\n")
        XCTAssertEqual(semicolons.songs.map(\.name), ["Intro, part 1"])

        var tabs = ShowSet()
        tabs.importSongs(csv: "Intro\t01:00:00:00\t01:04:00:00\nOutro\t02:00:00:00\t02:01:00:00")
        XCTAssertEqual(tabs.songs.map(\.name), ["Intro", "Outro"])

        var quotes = ShowSet()
        quotes.importSongs(csv: "\"The \"\"Big\"\" One\" , 01:00:00:00 , 01:04:00:00")
        XCTAssertEqual(quotes.songs.map(\.name), ["The \"Big\" One"])
    }

    func testIgnoresBlankLinesAndExtraColumns() {
        var set = ShowSet()
        let report = set.importSongs(csv: "\nIntro,01:00:00:00,01:04:00:00,,\n\n  \nOutro,02:00:00:00,02:01:00:00,notes\n")
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(set.songs.count, 2)
    }

    func testReportsInvalidRowsByLineAndImportsTheRest() {
        var set = ShowSet()
        let report = set.importSongs(csv: """
            Name,Start,End
            Intro,01:00:00:00,01:04:00:00
            Broken,1:00,01:05:00:00
            Short,02:00:00:00
            ,03:00:00:00,03:01:00:00
            Backwards,04:05:00:00,04:00:00:00
            Typo,05:00:00:00,05:61:00:00
            Outro,06:00:00:00,06:01:00:00
            """)
        XCTAssertEqual(set.songs.map(\.name), ["Intro", "Outro"])
        XCTAssertEqual(report.problems, [
            .init(line: 3, reason: .invalidStart("1:00")),
            .init(line: 4, reason: .tooFewColumns(2)),
            .init(line: 5, reason: .emptyName),
            .init(line: 6, reason: .endBeforeStart),
            .init(line: 7, reason: .invalidEnd("05:61:00:00")),
        ])
    }

    func testSkipsRowsOverlappingExistingSongsOrEarlierRows() {
        var set = ShowSet(songs: [Song(name: "Existing", start: tc("01:00:00:00"), end: tc("01:10:00:00"))])
        let report = set.importSongs(csv: """
            Clash,01:05:00:00,01:20:00:00
            First,02:00:00:00,02:10:00:00
            Second,02:09:00:00,02:15:00:00
            Touching,02:10:00:01,02:12:00:00
            """)
        XCTAssertEqual(set.songs.map(\.name), ["Existing", "First", "Touching"])
        XCTAssertEqual(report.problems, [
            .init(line: 1, reason: .overlaps("Existing")),
            .init(line: 3, reason: .overlaps("First")),
        ])
    }

    func testAHeaderIsOnlyRecognisedOnTheFirstRow() {
        var set = ShowSet()
        let report = set.importSongs(csv: "Intro,01:00:00:00,01:04:00:00\nName,Start,End")
        XCTAssertEqual(report.problems, [.init(line: 2, reason: .invalidStart("Start"))])
    }

    func testEmptyTextImportsNothing() {
        var set = ShowSet()
        XCTAssertEqual(set.importSongs(csv: ""), SongImportReport())
    }
}

/// Note Clashes: Start and Stop Notes that would trigger Songs together.
final class NoteClashTests: XCTestCase {
    let c3 = NoteTrigger(channel: 0, note: 60)
    let d3 = NoteTrigger(channel: 0, note: 62)

    func song(_ id: UInt64, start: NoteTrigger? = nil, stop: NoteTrigger? = nil) -> Song {
        Song(id: SongID(rawValue: id), name: "S\(id)", hasSpan: false, startNote: start, stopNote: stop)
    }

    func ids(_ raw: UInt64...) -> [SongID] { raw.map { SongID(rawValue: $0) } }

    func testDistinctNotesDoNotClash() {
        let set = ShowSet(songs: [song(1, start: c3), song(2, start: d3, stop: NoteTrigger(channel: 1, note: 60))])
        XCTAssertEqual(set.noteClashes, [])
    }

    func testASharedStartNoteClashesOnEverySongUsingIt() {
        let set = ShowSet(songs: [song(1, start: c3), song(2, start: d3), song(3, start: c3), song(4, start: c3)])
        XCTAssertEqual(set.noteClashes, [NoteClash(kind: .startNote, note: c3, songs: ids(1, 3, 4))])
    }

    func testASharedStopNoteClashes() {
        let set = ShowSet(songs: [song(1, stop: d3), song(2, stop: d3)])
        XCTAssertEqual(set.noteClashes, [NoteClash(kind: .stopNote, note: d3, songs: ids(1, 2))])
    }

    func testASongWhoseStartNoteIsItsStopNoteClashes() {
        let set = ShowSet(songs: [song(1, start: c3, stop: c3)])
        XCTAssertEqual(set.noteClashes, [NoteClash(kind: .startIsStop, note: c3, songs: ids(1))])
    }

    func testAStopNoteHandingOffToAnotherSongsStartNoteIsNotAClash() {
        let set = ShowSet(songs: [song(1, start: d3, stop: c3), song(2, start: c3)])
        XCTAssertEqual(set.noteClashes, [])
    }

    func testFixingTheNoteClearsTheClash() {
        var set = ShowSet(songs: [song(1, start: c3), song(2, start: c3)])
        XCTAssertFalse(set.noteClashes.isEmpty)
        set.apply(song(2, start: d3))
        XCTAssertEqual(set.noteClashes, [])
    }
}
