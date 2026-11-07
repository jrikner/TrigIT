import XCTest
import TrigITProtocols

final class MIDINoteTests: XCTestCase {
    func testEncodesNoteOnAndNoteOffPerMIDI1() {
        // Note On is 1001nnnn, Note Off 1000nnnn, where nnnn is the channel (0-based).
        let note = MIDINote(channel: 9, note: 36, velocity: 100)
        XCTAssertEqual(note.noteOn, [0x99, 0x24, 0x64])
        XCTAssertEqual(note.noteOff, [0x89, 0x24, 0x00])
    }

    func testClampsToValidRanges() {
        let note = MIDINote(channel: 20, note: 200, velocity: 0)
        XCTAssertEqual(note.noteOn, [0x9F, 127, 1], "velocity 0 would be a Note Off")
        XCTAssertEqual(MIDINote(channel: 0, note: 60, velocity: 200).velocity, 127)
    }

    func testRoundTripsThroughTheParser() {
        var parser = MIDIParser()
        let note = MIDINote(channel: 3, note: 64, velocity: 90)
        XCTAssertEqual(parser.parse(note.noteOn + note.noteOff),
                       [.noteOn(channel: 3, note: 64, velocity: 90), .noteOff(channel: 3, note: 64)])
    }

    func testNamesNotesWithMiddleCAsC3() {
        XCTAssertEqual(MIDINote(channel: 0, note: 60).noteName, "C3")
        XCTAssertEqual(MIDINote(channel: 0, note: 0).noteName, "C-2")
        XCTAssertEqual(MIDINote(channel: 0, note: 127).noteName, "G8")
    }
}

final class MSCTests: XCTestCase {
    func testEncodesGoWithCueAndList() {
        // MSC 1.0: F0 7F <device_ID> 02 <command_format> <command> <Q_number> 00 <Q_list> F7,
        // cue numbers as ASCII digits and ".".
        let command = MSCCommand(deviceID: 0x01, commandFormat: MSCCommand.Format.lighting, command: .go, cue: "235.6", list: "36")
        XCTAssertEqual(command.encoded, [0xF0, 0x7F, 0x01, 0x02, 0x01, 0x01,
                                         0x32, 0x33, 0x35, 0x2E, 0x36, 0x00, 0x33, 0x36, 0xF7])
    }

    func testEncodesGoWithoutACueAsGoNext() {
        XCTAssertEqual(MSCCommand(command: .go).encoded, [0xF0, 0x7F, 0x7F, 0x02, 0x7F, 0x01, 0xF7])
    }

    func testEncodesStopAndResume() {
        XCTAssertEqual(MSCCommand(deviceID: 0x70, commandFormat: 0x02, command: .stop, cue: "4").encoded,
                       [0xF0, 0x7F, 0x70, 0x02, 0x02, 0x02, 0x34, 0xF7])
        XCTAssertEqual(MSCCommand(command: .resume, cue: "4", list: "2").encoded,
                       [0xF0, 0x7F, 0x7F, 0x02, 0x7F, 0x03, 0x34, 0x00, 0x32, 0xF7])
    }

    func testValidatesCueNumbers() {
        XCTAssertTrue(MSCCommand(cue: "12.5", list: "3").isValid)
        XCTAssertTrue(MSCCommand().isValid)
        XCTAssertFalse(MSCCommand(cue: "1.2.3").isValid)
        XCTAssertFalse(MSCCommand(cue: "1a").isValid)
        XCTAssertFalse(MSCCommand(cue: ".5").isValid)
        XCTAssertFalse(MSCCommand(cue: "", list: "2").isValid, "a list needs a cue")
    }

    func testIsAWellFormedSysExForTheParser() {
        var parser = MIDIParser()
        let bytes = MSCCommand(cue: "1", list: "1").encoded
        XCTAssertEqual(parser.parse(bytes), [.systemExclusive(bytes)])
        XCTAssertTrue(bytes.dropFirst().dropLast().allSatisfy { $0 < 0x80 }, "SysEx data bytes are 7-bit")
    }

    func testSummaries() {
        XCTAssertEqual(MSCCommand(command: .go, cue: "5", list: "2").summary, "MSC GO cue 5 list 2")
        XCTAssertEqual(MSCCommand(command: .stop).summary, "MSC STOP")
    }
}
