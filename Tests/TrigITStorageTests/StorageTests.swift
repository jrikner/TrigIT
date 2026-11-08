import Foundation
import XCTest
import TrigITEngine
import TrigITProtocols
import TrigITStorage

/// A Set using every kind of Action and Destination setting.
func fullSet() -> ShowSet {
    let resolume = Destination(id: DestinationID(rawValue: 10), name: "Resolume", host: "10.0.0.20", port: 7000, networkInterface: "en1", replyPort: 7001)
    let ma3 = Destination(id: DestinationID(rawValue: 11), name: "MA3", host: "2.255.255.255", port: 8000,
                          midiOutput: MIDIPortReference(uniqueID: -123_456, name: "MA3 MIDI"), dmxOutput: .artNet)
    let intro = Song(
        id: SongID(rawValue: UInt64.max - 1), name: "Intro \"live\" ✨", start: Timecode("01:00:00:00")!, end: Timecode("01:04:00:00")!,
        startActions: [
            Action(id: ActionID(rawValue: 1), destinationID: resolume.id,
                   message: .osc(OSCMessage(address: "/composition/columns/1/connect",
                                            arguments: [.int(1), .float(0.5), .string("two words")]))),
            Action(id: ActionID(rawValue: 2), destinationID: ma3.id, message: .msc(MSCCommand(command: .go, cue: "12.5", list: "3"))),
        ],
        stopActions: [
            Action(id: ActionID(rawValue: 3), destinationID: ma3.id, message: .midiNote(MIDINote(channel: 9, note: 36, velocity: 100))),
            Action(id: ActionID(rawValue: 4), destinationID: ma3.id, message: .dmxPulse(DMXPulse(universe: 2, channel: 101, value: 200, duration: 0.25))),
        ]
    )
    let pullUp = Song(id: SongID(rawValue: 2), name: "DJ Pull-up", start: Timecode("02:00:00:00")!, end: Timecode("02:01:30:00")!)
    return ShowSet(id: SetID(rawValue: 77), name: "Tour 2026", songs: [intro, pullUp], destinations: [resolume, ma3], stopTime: 3.5)
}

final class SetFileTests: XCTestCase {
    func testRoundTripsEveryKindOfContent() throws {
        let set = fullSet()
        XCTAssertEqual(try SetFile.decode(SetFile.encode(set)), set)
    }

    func testIsReadableJSON() throws {
        let text = String(decoding: try SetFile.encode(fullSet()), as: UTF8.self)
        for expected in [#""format" : "TrigIT Set""#, #""version" : 1"#, #""start" : "01:00:00:00""#,
                         #""type" : "osc""#, #""address" : "/composition/columns/1/connect""#,
                         #""dmxOutput" : "artNet""#, #""command" : "go""#, #""stopTime" : 3.5"#, #""id" : "18446744073709551614""#] {
            XCTAssertTrue(text.contains(expected), "missing \(expected)")
        }
        XCTAssertTrue(text.contains("\n"), "pretty-printed")
    }

    func testOpensAMinimalHandWrittenFileUsingDefaults() throws {
        // As an older TrigIT, or a person, might write it: no IDs, no Actions, no Stop time.
        let text = """
            {"format": "TrigIT Set", "version": 1, "set": {
              "name": "Hand made",
              "songs": [{"name": "Intro", "start": "01:00:00:00", "end": "01:04:00:00"}],
              "destinations": [{"name": "Resolume", "host": "10.0.0.20", "port": 7000}]
            }}
            """
        let set = try SetFile.decode(Data(text.utf8))
        XCTAssertEqual(set.name, "Hand made")
        XCTAssertEqual(set.stopTime, ShowSet.defaultStopTime)
        XCTAssertEqual(set.songs.first?.startActions, [])
        XCTAssertEqual(set.songs.first?.stopActions, [])
        XCTAssertNil(set.destinations.first?.midiOutput)
        XCTAssertNil(set.destinations.first?.replyPort)
        XCTAssertEqual(set.destinations.first?.transports, [.osc])
    }

    func testOpensDestinationsFromBeforeTheTransportSwitchesAsTheyBehaved() throws {
        let text = """
            {"format": "TrigIT Set", "version": 1, "set": {"destinations": [
              {"name": "MA3", "host": "10.0.0.30", "port": 8000, "dmxOutput": "sACNUnicast",
               "midiOutput": {"uniqueID": 42, "name": "MA3 MIDI"}}
            ]}}
            """
        let ma3 = try XCTUnwrap(SetFile.decode(Data(text.utf8)).destinations.first)
        XCTAssertEqual(ma3.transports, [.osc, .midi, .dmx])
    }

    func testOldSetsSendDMXToTheOSCAddressAndInterface() throws {
        let text = """
            {"format": "TrigIT Set", "version": 1, "set": {"destinations": [
              {"name": "MA3", "host": "10.0.0.30", "port": 8000, "networkInterface": "en7", "dmxOutput": "artNet"}
            ]}}
            """
        let ma3 = try XCTUnwrap(SetFile.decode(Data(text.utf8)).destinations.first)
        XCTAssertEqual(ma3.dmxHost, "10.0.0.30")
        XCTAssertEqual(ma3.dmxInterface, "en7")
        XCTAssertEqual(ma3.sacnPriority, 100)
        XCTAssertEqual(ma3.dmxSourceName, "TrigIT")
        XCTAssertEqual(ma3.dmxRefreshRate, 30)
    }

    func testDMXKeepsItsOwnAddressAndAnAutomaticInterface() throws {
        var set = fullSet()
        set.destinations[1].networkInterface = "en1"
        set.destinations[1].dmxInterface = nil
        set.destinations[1].dmxHost = "2.0.0.10"
        set.destinations[1].sacnPriority = 150
        set.destinations[1].dmxSourceName = "Stage left"
        set.destinations[1].dmxRefreshRate = 40
        let reopened = try SetFile.decode(SetFile.encode(set)).destinations[1]
        XCTAssertEqual(reopened, set.destinations[1])
        XCTAssertNil(reopened.dmxInterface, "Automatic stays Automatic rather than copying the OSC interface")
    }

    func testClampsSACNPriorityAndRefreshRate() {
        var lights = Destination(name: "Lights", host: "", port: 0, sacnPriority: 255, dmxRefreshRate: 500)
        XCTAssertEqual(lights.sacnPriority, 200)
        XCTAssertEqual(lights.dmxRefreshRate, 44)
        lights.dmxRefreshRate = 0
        XCTAssertEqual(lights.dmxRefreshRate, 1)
    }

    func testASwitchedOffTransportKeepsItsSettings() throws {
        var set = fullSet()
        set.destinations[1].usesMIDI = false
        set.destinations[1].usesOSC = false
        let reopened = try SetFile.decode(SetFile.encode(set)).destinations[1]
        XCTAssertEqual(reopened.transports, [.dmx])
        XCTAssertEqual(reopened.midiOutput?.uniqueID, -123_456)
        XCTAssertEqual(reopened.port, 8000)
        XCTAssertNil(reopened.activeMIDIOutput)
    }

    func testClampsAnOutOfRangeStopTime() throws {
        let text = #"{"format": "TrigIT Set", "version": 1, "set": {"stopTime": 500}}"#
        XCTAssertEqual(try SetFile.decode(Data(text.utf8)).stopTime, ShowSet.stopTimeRange.upperBound)
    }

    func testExplainsFilesItCannotOpen() {
        let cases: [(String, SetFile.ReadError)] = [
            ("not json at all", .notJSON),
            (#"{"hello": "world"}"#, .notATrigITSet),
            (#"{"format": "TrigIT Set"}"#, .notATrigITSet),
            (#"{"format": "TrigIT Set", "version": 2, "set": {}}"#, .newerVersion(2)),
            (#"{"format": "TrigIT Set", "version": 1}"#, .invalid(#"it has no "set""#)),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try SetFile.decode(Data(text.utf8)), text) { error in
                XCTAssertEqual(error as? SetFile.ReadError, expected, text)
            }
        }
    }

    func testPointsAtTheDamagedPart() {
        let text = #"{"format": "TrigIT Set", "version": 1, "set": {"songs": [{"name": "A", "start": "1:00", "end": "01:00:01:00"}]}}"#
        XCTAssertThrowsError(try SetFile.decode(Data(text.utf8))) { error in
            guard case .invalid(let reason) = error as? SetFile.ReadError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("not a timecode"), reason)
            XCTAssertTrue(reason.contains("songs"), reason)
        }
    }

    func testRejectsAnActionOfUnknownType() {
        let text = """
            {"format": "TrigIT Set", "version": 1, "set": {"songs": [{"name": "A", "start": "01:00:00:00", "end": "01:00:01:00",
              "startActions": [{"destination": "1", "type": "laser"}]}]}}
            """
        XCTAssertThrowsError(try SetFile.decode(Data(text.utf8)))
    }

    func testWritesAndReadsAFile() throws {
        let url = try temporaryDirectory().appendingPathComponent("Show.trigit")
        try SetFile.write(fullSet(), to: url)
        XCTAssertEqual(try SetFile.read(from: url), fullSet())
    }

    func testReportsAMissingFile() throws {
        let url = try temporaryDirectory().appendingPathComponent("Missing.trigit")
        XCTAssertThrowsError(try SetFile.read(from: url)) { error in
            guard case .unreadable = error as? SetFile.ReadError else { return XCTFail("\(error)") }
        }
    }
}

final class SetVersionStoreTests: XCTestCase {
    func testKeepsVersionsNewestFirstAndRestoresThem() throws {
        let store = SetVersionStore(directory: try temporaryDirectory())
        var set = fullSet()
        try store.save(set, at: Date(timeIntervalSince1970: 1_000))
        set.name = "Renamed"
        try store.save(set, at: Date(timeIntervalSince1970: 2_000))
        let versions = store.versions(of: set.id)
        XCTAssertEqual(versions.map(\.date), [Date(timeIntervalSince1970: 2_000), Date(timeIntervalSince1970: 1_000)])
        XCTAssertEqual(try SetFile.read(from: versions[1].url).name, "Tour 2026")
    }

    func testKeepsOnlyTheNewestUpToTheLimit() throws {
        let store = SetVersionStore(directory: try temporaryDirectory(), limit: 3)
        for second in 1...5 {
            try store.save(fullSet(), at: Date(timeIntervalSince1970: Double(second)))
        }
        XCTAssertEqual(store.versions(of: fullSet().id).map(\.date.timeIntervalSince1970), [5, 4, 3])
    }

    func testSetsKeepSeparateVersions() throws {
        let store = SetVersionStore(directory: try temporaryDirectory())
        try store.save(fullSet(), at: Date(timeIntervalSince1970: 1))
        try store.save(ShowSet(id: SetID(rawValue: 5)), at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(store.versions(of: fullSet().id).count, 1)
        XCTAssertEqual(store.versions(of: SetID(rawValue: 5)).count, 1)
        XCTAssertEqual(store.versions(of: SetID(rawValue: 6)), [])
    }

    func testRemembersVersionsUsedInAShow() throws {
        let store = SetVersionStore(directory: try temporaryDirectory())
        try store.save(fullSet(), at: Date(timeIntervalSince1970: 1))
        let used = try store.save(fullSet(), at: Date(timeIntervalSince1970: 2))
        store.markUsedInShow(used)
        XCTAssertEqual(store.versions(of: fullSet().id).map(\.usedInShow), [true, false])
    }
}

final class EditHistoryTests: XCTestCase {
    func testUndoesAndRedoesEdits() {
        var history = EditHistory<Int>()
        history.record(before: 0, at: 0)
        history.record(before: 1, at: 10)
        XCTAssertEqual(history.undo(from: 2), 1)
        XCTAssertEqual(history.undo(from: 1), 0)
        XCTAssertNil(history.undo(from: 0))
        XCTAssertEqual(history.redo(from: 0), 1)
        XCTAssertEqual(history.redo(from: 1), 2)
        XCTAssertNil(history.redo(from: 2))
    }

    func testEditsInQuickSuccessionUndoAsOne() {
        var history = EditHistory<String>(coalescing: 1)
        history.record(before: "", at: 0)
        history.record(before: "I", at: 0.3)
        history.record(before: "In", at: 0.6)
        history.record(before: "Int", at: 0.9)
        XCTAssertEqual(history.undo(from: "Intr"), "")
        XCTAssertFalse(history.canUndo)
    }

    func testAPauseStartsANewStep() {
        var history = EditHistory<String>(coalescing: 1)
        history.record(before: "", at: 0)
        history.record(before: "A", at: 5)
        XCTAssertEqual(history.undo(from: "AB"), "A")
    }

    func testANewEditClearsRedo() {
        var history = EditHistory<Int>()
        history.record(before: 0, at: 0)
        _ = history.undo(from: 1)
        history.record(before: 0, at: 10)
        XCTAssertFalse(history.canRedo)
    }

    func testAnEditRightAfterUndoIsItsOwnStep() {
        var history = EditHistory<Int>(coalescing: 1)
        history.record(before: 0, at: 0)
        history.record(before: 1, at: 5)
        _ = history.undo(from: 2) // back to 1
        history.record(before: 1, at: 5.1)
        XCTAssertEqual(history.undo(from: 3), 1)
        XCTAssertEqual(history.undo(from: 1), 0)
    }

    func testDropsTheOldestBeyondTheLimit() {
        var history = EditHistory<Int>(limit: 2, coalescing: 0)
        for value in 0..<5 { history.record(before: value, at: Double(value)) }
        XCTAssertEqual(history.undo(from: 5), 4)
        XCTAssertEqual(history.undo(from: 4), 3)
        XCTAssertNil(history.undo(from: 3))
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("TrigITTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class ShowLogTests: XCTestCase {
    var folder: URL!
    var calendar = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testWritesOneFilePerDayWithTimestampedLines() throws {
        let log = ShowLog(directory: folder, calendar: calendar)
        try log.append("Armed", at: date("2026-11-07T21:00:00Z"))
        try log.append("Fired Intro", at: date("2026-11-07T21:00:01Z"))
        try log.append("Timecode stopped", at: date("2026-11-08T00:30:00Z"))
        let first = try String(contentsOf: folder.appendingPathComponent("2026-11-07.log"), encoding: .utf8)
        XCTAssertEqual(first, "21:00:00.000  Armed\n21:00:01.000  Fired Intro\n")
        let second = try String(contentsOf: folder.appendingPathComponent("2026-11-08.log"), encoding: .utf8)
        XCTAssertEqual(second, "00:30:00.000  Timecode stopped\n")
    }

    func testRemovesFilesOlderThan30Days() throws {
        let log = ShowLog(directory: folder, calendar: calendar)
        for day in ["2026-10-07", "2026-10-08", "2026-11-07"] {
            try log.append("x", at: date("\(day)T12:00:00Z"))
        }
        try Data().write(to: folder.appendingPathComponent("notes.txt"))
        log.removeOldFiles(now: date("2026-11-07T23:00:00Z"))
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, ["2026-10-08.log", "2026-11-07.log", "notes.txt"])
    }
}
