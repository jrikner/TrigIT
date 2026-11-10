// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
import TrigITEngine
import TrigITProtocols
import TrigITStorage

/// The `.trigit` files the MA3 plugin's Lua tests read (ma3-plugin/spec/fixtures)
/// are written by this Swift code, so they stay real Set files. Each test
/// checks the checked-in file still opens as the Set built here; run with
/// TRIGIT_WRITE_FIXTURES=1 to rewrite them after changing a Set or the format.
final class MA3FixtureTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ma3-plugin/spec/fixtures")

    func testExampleSetFixture() throws {
        try check(Self.withFixedIDs(.example), "example.trigit")
    }

    /// Every kind of Action, Stop Actions, Songs with only notes, and an
    /// overlap a hand-edited file could have.
    func testFullSetFixture() throws {
        var set = fullSet()
        let ma3 = set.destinations[1].id
        set.songs += [
            Song(id: SongID(rawValue: 3), name: "Start Note only", hasSpan: false, startNote: NoteTrigger(channel: 0, note: 60),
                 startActions: [Action(id: ActionID(rawValue: 5), destinationID: ma3, message: .midiNote(MIDINote(channel: 0, note: 1)))]),
            Song(id: SongID(rawValue: 4), name: "Stop Note only", hasSpan: false, stopNote: NoteTrigger(channel: 0, note: 61)),
            Song(id: SongID(rawValue: 5), name: "Overlaps Intro", start: Timecode("01:03:00:00")!, end: Timecode("01:05:00:00")!,
                 startActions: [Action(id: ActionID(rawValue: 6), destinationID: ma3, message: .midiNote(MIDINote(channel: 0, note: 2)))]),
        ]
        try check(set, "full.trigit")
    }

    /// The other way: a Set made and saved by the plugin's editor (#96,
    /// spec/setedit_spec.lua writes the file) opens in the Mac app as made.
    func testConsoleWrittenSetOpens() throws {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent("console-written.trigit"))
        let set = try SetFile.decode(data)
        XCTAssertEqual(set.name, "Made on the console")
        XCTAssertEqual(set.stopTime, 2)
        XCTAssertEqual(set.destinations.map(\.name), ["Resolume"])
        let resolume = try XCTUnwrap(set.destinations.first)
        XCTAssertEqual(resolume.host, "192.168.1.20")
        XCTAssertEqual(resolume.port, 7000)
        XCTAssertEqual(set.songs.map(\.name), ["Intro", "Outro"])
        let intro = set.songs[0]
        XCTAssertEqual(intro.start, Timecode("01:00:00:00"))
        XCTAssertEqual(intro.end, Timecode("01:04:00:00"))
        XCTAssertEqual(intro.startActions.first?.destinationID, resolume.id)
        XCTAssertEqual(intro.startActions.first?.message,
                       .osc(OSCMessage(address: "/composition/columns/1/connect", arguments: [.int(1), .float(0.5), .string("go now")])))
        XCTAssertEqual(intro.stopActions.first?.message, .midiNote(MIDINote(channel: 9, note: 36, velocity: 100)))
        XCTAssertEqual(set.songs[1].start, Timecode("01:05:00:00"))
    }

    private func check(_ set: ShowSet, _ name: String) throws {
        let url = Self.folder.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["TRIGIT_WRITE_FIXTURES"] != nil {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try SetFile.write(set, to: url)
        }
        XCTAssertEqual(try SetFile.read(from: url), set, "\(name) is out of date: run swift test with TRIGIT_WRITE_FIXTURES=1")
    }

    /// The example Set has random IDs; number them so the file doesn't change.
    private static func withFixedIDs(_ set: ShowSet) -> ShowSet {
        var set = set
        set.id = SetID(rawValue: 1)
        var destinationIDs: [DestinationID: DestinationID] = [:]
        for index in set.destinations.indices {
            let fixed = DestinationID(rawValue: UInt64(100 + index))
            destinationIDs[set.destinations[index].id] = fixed
            set.destinations[index].id = fixed
        }
        var actionNumber: UInt64 = 1000
        func fix(_ actions: [Action]) -> [Action] {
            actions.map { action in
                actionNumber += 1
                return Action(id: ActionID(rawValue: actionNumber), destinationID: destinationIDs[action.destinationID]!, message: action.message)
            }
        }
        for index in set.songs.indices {
            set.songs[index].id = SongID(rawValue: UInt64(10 + index))
            set.songs[index].startActions = fix(set.songs[index].startActions)
            set.songs[index].stopActions = fix(set.songs[index].stopActions)
        }
        return set
    }
}
