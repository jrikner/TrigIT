// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import TrigITEngine
import TrigITProtocols

/// Start Notes and Stop Notes: Songs triggered by MIDI notes, alone or with timecode.
final class NoteTriggerTests: XCTestCase {
    let resolume = Destination(id: DestinationID(rawValue: 10), name: "Resolume", host: "10.0.0.20", port: 7000)

    lazy var startA = osc(1, "/a/start")
    lazy var stopA = osc(2, "/a/stop")
    lazy var startB = osc(3, "/b/start")
    lazy var pullUp = osc(4, "/pullup")

    let noteA = NoteTrigger(channel: 0, note: 60)
    let stopNoteA = NoteTrigger(channel: 0, note: 61)
    let noteB = NoteTrigger(channel: 1, note: 60)
    let pullUpNote = NoteTrigger(channel: 0, note: 72)

    /// A has a span and both notes; B has a span only; P has only a Start Note;
    /// Q has only a Stop Note.
    lazy var songA = Song(id: SongID(rawValue: 1), name: "A", start: tc("01:00:00:00"), end: tc("01:00:10:00"),
                          startNote: noteA, stopNote: stopNoteA, startActions: [startA], stopActions: [stopA])
    lazy var songB = Song(id: SongID(rawValue: 2), name: "B", start: tc("01:00:20:00"), end: tc("01:00:30:00"),
                          startActions: [startB])
    lazy var songP = Song(id: SongID(rawValue: 3), name: "P", hasSpan: false, startNote: noteB, startActions: [startB])
    lazy var songQ = Song(id: SongID(rawValue: 4), name: "Q", hasSpan: false, stopNote: pullUpNote, stopActions: [pullUp])

    func makeTimeline(armed: Bool = true) -> Timeline {
        Timeline(set: ShowSet(songs: [songA, songB, songP, songQ], destinations: [resolume]), armed: armed)
    }

    func noteOn(_ trigger: NoteTrigger, velocity: UInt8 = 100) -> MIDIMessage {
        .noteOn(channel: trigger.channel, note: trigger.note, velocity: velocity)
    }

    func testAStartNoteWithNoTimecodeMakesTheSongEnter() {
        let timeline = makeTimeline()
        timeline.midi(noteOn(noteA))
        XCTAssertEqual(timeline.events.filter { if case .fired = $0 { return true } else { return false } },
                       [.fired(songA.id, .note)])
        XCTAssertEqual(timeline.sends.map(\.action), [startA])
        XCTAssertEqual(timeline.engine.currentSongID, songA.id)
    }

    func testAStartNoteForTheCurrentSongFiresNothing() {
        let timeline = makeTimeline()
        timeline.midi(noteOn(noteA))
        timeline.clearEvents()
        timeline.midi(noteOn(noteA))
        XCTAssertEqual(timeline.events, [])
    }

    func testTimecodeEnteringASongItsStartNoteAlreadyFiredFiresNothing() {
        let timeline = makeTimeline()
        timeline.midi(noteOn(noteA))
        timeline.clearEvents()
        timeline.play(from: "01:00:00:00", frames: 50)
        XCTAssertEqual(timeline.fired, [])
        XCTAssertEqual(timeline.sends, [])
        XCTAssertEqual(timeline.engine.currentSongID, songA.id)
    }

    func testAStopNoteAfterATimecodeStopEndsTheSongAndSendsItsStopActions() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:01:00", frames: 25)
        timeline.silence(3)
        timeline.clearEvents()
        timeline.midi(noteOn(stopNoteA))
        XCTAssertEqual(timeline.ended, [.ended(songA.id, .note)])
        XCTAssertEqual(timeline.sends.map(\.action), [stopA])
        XCTAssertNil(timeline.engine.currentSongID)
    }

    func testAStopNoteForTheCurrentSongSendsItsStopActionsOnce() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:01:00", frames: 25)
        timeline.clearEvents()
        timeline.midi(noteOn(stopNoteA))
        timeline.midi(noteOn(stopNoteA))
        timeline.play(frames: 25)
        XCTAssertEqual(timeline.ended, [.ended(songA.id, .note)])
        XCTAssertEqual(timeline.sends.map(\.action), [stopA])
        XCTAssertNil(timeline.engine.currentSongID)
    }

    func testATimecodeStopAfterTheStopNoteSendsNothing() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:01:00", frames: 25)
        timeline.midi(noteOn(stopNoteA))
        timeline.clearEvents()
        timeline.silence(3)
        XCTAssertEqual(timeline.ended, [])
        XCTAssertEqual(timeline.sends, [])
    }

    func testAStopNoteForASongThatIsNotCurrentSendsNothing() {
        let timeline = makeTimeline()
        timeline.midi(noteOn(stopNoteA))
        timeline.play(from: "01:00:21:00", frames: 25) // in B
        timeline.clearEvents()
        timeline.midi(noteOn(stopNoteA))
        XCTAssertEqual(timeline.events, [])
    }

    func testASongWithOnlyAStopNoteSendsItsStopActionsEveryTimeAndNeverBecomesCurrent() {
        let timeline = makeTimeline()
        timeline.midi(noteOn(pullUpNote))
        timeline.play(from: "01:00:01:00", frames: 25)
        timeline.midi(noteOn(pullUpNote))
        XCTAssertEqual(timeline.ended, [.ended(songQ.id, .note), .ended(songQ.id, .note)])
        XCTAssertEqual(timeline.sends.map(\.action), [pullUp, startA, pullUp])
        XCTAssertFalse(timeline.songChanges.contains(songQ.id))
        XCTAssertEqual(timeline.engine.currentSongID, songA.id)
    }

    func testASongWithOnlyAStartNoteStaysCurrentThroughATimecodeStop() {
        let timeline = makeTimeline()
        timeline.play(from: "00:59:00:00", frames: 25) // timecode outside every Song
        timeline.midi(noteOn(noteB))
        timeline.play(frames: 50)
        XCTAssertEqual(timeline.engine.currentSongID, songP.id)
        timeline.silence(3)
        XCTAssertEqual(timeline.ended, [])
        XCTAssertEqual(timeline.engine.currentSongID, songP.id)
    }

    func testASongWithOnlyAStartNoteStaysCurrentUntilAnotherSongIsEntered() {
        let timeline = makeTimeline()
        timeline.midi(noteOn(noteB))
        timeline.play(from: "00:59:59:00", frames: 20)
        XCTAssertEqual(timeline.engine.currentSongID, songP.id)
        timeline.play(frames: 10) // into A
        XCTAssertEqual(timeline.engine.currentSongID, songA.id)
        XCTAssertEqual(timeline.fired, [songP.id, songA.id])
    }

    func testNoteOffIsIgnoredAndVelocityZeroCountsAsNoteOff() {
        let timeline = makeTimeline()
        timeline.midi(.noteOff(channel: 0, note: 60))
        timeline.midi(noteOn(noteA, velocity: 0))
        timeline.midi(noteOn(pullUpNote, velocity: 0))
        XCTAssertEqual(timeline.events, [])
        var parser = MIDIParser()
        XCTAssertEqual(parser.parse([0x90, 60, 0]), [.noteOff(channel: 0, note: 60)])
    }

    func testANoteOnAnotherChannelDoesNothing() {
        let timeline = makeTimeline()
        timeline.midi(.noteOn(channel: 2, note: 60, velocity: 100))
        XCTAssertEqual(timeline.events, [])
    }

    func testWhileDisarmedNothingIsSentButTheCurrentSongIsTracked() {
        let timeline = makeTimeline(armed: false)
        timeline.midi(noteOn(noteA))
        timeline.midi(noteOn(pullUpNote))
        XCTAssertEqual(timeline.engine.currentSongID, songA.id)
        timeline.midi(noteOn(stopNoteA))
        XCTAssertNil(timeline.engine.currentSongID)
        XCTAssertEqual(timeline.sends, [])
        timeline.setArmed(true)
        timeline.midi(noteOn(noteA))
        XCTAssertEqual(timeline.sends.map(\.action), [startA])
    }

    // MARK: Set rules and file

    func testASongWithoutASpanOverlapsNothing() {
        var set = ShowSet(songs: [songA])
        var spanless = songP
        spanless.start = songA.start
        spanless.end = songA.end
        XCTAssertEqual(set.apply(spanless), [])
        XCTAssertEqual(set.song(at: tc("01:00:01:00"))?.id, songA.id)
    }

    func testHasTrigger() {
        XCTAssertTrue(songB.hasTrigger)
        XCTAssertTrue(songP.hasTrigger)
        XCTAssertTrue(songQ.hasTrigger)
        XCTAssertFalse(Song(name: "none", hasSpan: false).hasTrigger)
    }

    func testNotesAndMissingSpansRoundTripThroughTheFile() throws {
        let set = ShowSet(songs: [songA, songP, songQ], destinations: [resolume])
        let decoded = try JSONDecoder().decode(ShowSet.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(decoded, set)
    }

    func testAnOldSongWithoutNotesStillOpens() throws {
        let json = #"{"id":"1","name":"A","start":"01:00:00:00","end":"01:00:10:00"}"#
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        XCTAssertTrue(song.hasSpan)
        XCTAssertNil(song.startNote)
        XCTAssertNil(song.stopNote)
    }

    private func osc(_ id: UInt64, _ address: String) -> Action {
        Action(id: ActionID(rawValue: id), destinationID: resolume.id, message: .osc(OSCMessage(address: address)))
    }
}
