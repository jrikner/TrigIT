import XCTest
import TrigITEngine
import TrigITProtocols

/// Learn turns the first captured message into an Action, or a Song's Start Note.
final class LearnTests: XCTestCase {
    func testOSCMessageBecomesOSCAction() {
        // "/composition/layers/2/clips/5/connect" with int 1, float 0.5 and string "go", as Resolume or TouchOSC sends it.
        let packet = OSCMessage(address: "/composition/layers/2/clips/5/connect",
                                arguments: [.int(1), .float(0.5), .string("go")]).encoded()
        XCTAssertEqual(Learn.actionMessage(fromOSC: packet),
                       .osc(OSCMessage(address: "/composition/layers/2/clips/5/connect",
                                       arguments: [.int(1), .float(0.5), .string("go")])))
    }

    func testOSCSpecExampleBytesDecode() {
        // The OSC 1.0 spec's "/foo" example, written out byte by byte.
        let packet: [UInt8] = [
            0x2f, 0x66, 0x6f, 0x6f, 0x00, 0x00, 0x00, 0x00, 0x2c, 0x69, 0x69, 0x73, 0x66, 0x66, 0x00, 0x00,
            0x00, 0x00, 0x03, 0xe8, 0xff, 0xff, 0xff, 0xff, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 0x00,
            0x3f, 0x9d, 0xf3, 0xb6, 0x40, 0xb5, 0xb2, 0x2d,
        ]
        XCTAssertEqual(Learn.actionMessage(fromOSC: packet),
                       .osc(OSCMessage(address: "/foo", arguments: [.int(1000), .int(-1), .string("hello"),
                                                                   .float(1.234), .float(5.678)])))
    }

    func testOSCBundleYieldsItsFirstMessage() {
        let inner = OSCMessage(address: "/go", arguments: [.int(1)]).encoded()
        let size = UInt32(inner.count)
        let packet = Array("#bundle".utf8) + [0] + [0, 0, 0, 0, 0, 0, 0, 1]
            + [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)] + inner
        XCTAssertEqual(Learn.actionMessage(fromOSC: packet), .osc(OSCMessage(address: "/go", arguments: [.int(1)])))
    }

    func testOSCTrueAndFalseBecomeInts() {
        let packet = Array("/t".utf8) + [0, 0] + Array(",TF".utf8) + [0]
        XCTAssertEqual(Learn.actionMessage(fromOSC: packet), .osc(OSCMessage(address: "/t", arguments: [.int(1), .int(0)])))
    }

    func testNonOSCPacketsAreIgnored() {
        XCTAssertNil(Learn.actionMessage(fromOSC: []))
        XCTAssertNil(Learn.actionMessage(fromOSC: Array("Art-Net".utf8) + [0, 0x00, 0x97]))
        XCTAssertNil(Learn.actionMessage(fromOSC: Array("/x".utf8) + [0, 0] + Array(",b".utf8) + [0, 0, 0, 0, 0, 1, 7]))
    }

    func testNoteOnBecomesMIDINoteAction() {
        var parser = MIDIParser()
        let messages = parser.parse([0x92, 60, 100]) // Note On, channel 3, middle C, velocity 100
        XCTAssertEqual(messages.compactMap(Learn.actionMessage(from:)),
                       [.midiNote(MIDINote(channel: 2, note: 60, velocity: 100))])
    }

    func testMSCGoBecomesMSCAction() {
        // GO cue 12.5 in list 3, device 1, lighting format.
        var parser = MIDIParser()
        let bytes: [UInt8] = [0xF0, 0x7F, 0x01, 0x02, 0x01, 0x01] + Array("12.5".utf8) + [0x00] + Array("3".utf8) + [0xF7]
        XCTAssertEqual(parser.parse(bytes).compactMap(Learn.actionMessage(from:)),
                       [.msc(MSCCommand(deviceID: 1, commandFormat: 0x01, command: .go, cue: "12.5", list: "3"))])
    }

    func testMSCWithoutCueRoundTrips() {
        let command = MSCCommand(command: .stop)
        XCTAssertEqual(Learn.actionMessage(from: .systemExclusive(command.encoded)), .msc(command))
    }

    func testOtherMIDIIsIgnored() {
        XCTAssertNil(Learn.actionMessage(from: .noteOff(channel: 0, note: 60)))
        XCTAssertNil(Learn.actionMessage(from: .quarterFrame(0x12)))
        // An MTC full frame is SysEx but not MSC.
        XCTAssertNil(Learn.actionMessage(from: .systemExclusive([0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x20, 0, 0, 0, 0xF7])))
        // An MSC command TrigIT doesn't send (SET).
        XCTAssertNil(Learn.actionMessage(from: .systemExclusive([0xF0, 0x7F, 0x7F, 0x02, 0x7F, 0x06, 0xF7])))
    }

    func testNoteOnSetsStartNote() {
        var parser = MIDIParser()
        let triggers = parser.parse([0x80, 60, 0, 0x9F, 36, 127]).compactMap(Learn.noteTrigger(from:))
        XCTAssertEqual(triggers, [NoteTrigger(channel: 15, note: 36)])

        // The learned note triggers the Song through the engine's public input.
        let resolume = Destination(name: "Resolume", host: "127.0.0.1", port: 7000)
        let go = Action(destinationID: resolume.id, message: .osc(OSCMessage(address: "/go")))
        let song = Song(name: "Intro", hasSpan: false, startNote: triggers.first, startActions: [go])
        let timeline = Timeline(set: ShowSet(songs: [song], destinations: [resolume]), armed: true)
        timeline.midi(.noteOn(channel: 15, note: 36, velocity: 90))
        XCTAssertEqual(timeline.sends.map(\.action), [go])
    }
}
