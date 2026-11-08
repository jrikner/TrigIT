// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import TrigITProtocols

final class MIDIParserTests: XCTestCase {
    func testParsesNotesWithRunningStatus() {
        var parser = MIDIParser()
        XCTAssertEqual(parser.parse([0x92, 60, 100, 62, 90, 60, 0, 0x81, 64, 10]), [
            .noteOn(channel: 2, note: 60, velocity: 100),
            .noteOn(channel: 2, note: 62, velocity: 90),
            .noteOff(channel: 2, note: 60), // Note On with velocity 0 is a Note Off
            .noteOff(channel: 1, note: 64),
        ])
    }

    func testMessagesMaySplitAcrossPackets() {
        var parser = MIDIParser()
        XCTAssertEqual(parser.parse([0x90, 60]), [])
        XCTAssertEqual(parser.parse([127]), [.noteOn(channel: 0, note: 60, velocity: 127)])
        XCTAssertEqual(parser.parse([0xF0, 0x7F, 0x7F, 0x01]), [])
        XCTAssertEqual(parser.parse([0x01, 0x21, 0x02, 0x03, 0x04, 0xF7]),
                       [.systemExclusive([0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x21, 0x02, 0x03, 0x04, 0xF7])])
    }

    func testRealTimeBytesAreIgnoredWherverTheyAppear() {
        var parser = MIDIParser()
        XCTAssertEqual(parser.parse([0x90, 0xF8, 60, 0xFE, 100, 0xF1, 0xF8, 0x23, 0xF0, 0x7F, 0xF8, 0xF7]), [
            .noteOn(channel: 0, note: 60, velocity: 100),
            .quarterFrame(0x23),
            .systemExclusive([0xF0, 0x7F, 0xF7]),
        ])
    }

    func testSystemCommonCancelsRunningStatus() {
        var parser = MIDIParser()
        XCTAssertEqual(parser.parse([0x90, 60, 100, 0xF1, 0x10, 61, 100]), [
            .noteOn(channel: 0, note: 60, velocity: 100),
            .quarterFrame(0x10),
        ])
    }

    func testSkipsMessagesItDoesNotUse() {
        var parser = MIDIParser()
        XCTAssertEqual(parser.parse([0xB0, 7, 100, 0xC0, 5, 0xE0, 0, 64, 0xF2, 1, 2, 0x90, 60, 1]),
                       [.noteOn(channel: 0, note: 60, velocity: 1)])
    }

    func testDropsOverlongSystemExclusive() {
        var parser = MIDIParser()
        let long = [0xF0] + [UInt8](repeating: 1, count: 300) + [0xF7]
        XCTAssertEqual(parser.parse(long), [])
    }
}

final class MTCTests: XCTestCase {
    func testEncodesQuarterFramesPerTheMIDISpec() {
        // 01:37:52:16 at 25 fps: frames 0x10 → pieces 0x00, 0x11; seconds 52 = 0x34 →
        // 0x24, 0x33; minutes 37 = 0x25 → 0x45, 0x52; hours 1 with rate code 1 → 0x61, 0x72.
        let fields = TimecodeFields(hours: 1, minutes: 37, seconds: 52, frames: 16)
        XCTAssertEqual(MTCEncoder.quarterFrames(fields, rate: .fps25), [0x00, 0x11, 0x24, 0x33, 0x45, 0x52, 0x61, 0x72])
        XCTAssertEqual(MTCEncoder.fullFrame(fields, rate: .fps25), [0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x21, 37, 52, 16, 0xF7])
    }

    func testEightQuarterFramesReportTheTimeTwoFramesOn() {
        var decoder = MTCDecoder()
        let times = feed(&decoder, MTCEncoder.quarterFrames(fields(1, 0, 0, 10), rate: .fps25))
        XCTAssertEqual(times, [MTCTime(fields: fields(1, 0, 0, 12), frameRate: .fps25, kind: .quarterFrame)])
    }

    func testRunningMTCReportsEveryFrame() {
        for rate in FrameRate.allCases {
            var decoder = MTCDecoder()
            let start = fields(0, 9, 59, 0)
            let times = feed(&decoder, runningQuarterFrames(from: start, rate: rate, sets: 30))
            // The first set only locks on; after that one time per frame, consecutive.
            XCTAssertEqual(times.count, 1 + 2 * 29, "\(rate)")
            let expected = (0..<times.count).map { start.advanced(by: 2 + $0, rate: rate) }
            XCTAssertEqual(times.map(\.fields), expected, "\(rate)")
            XCTAssertTrue(times.allSatisfy { $0.frameRate == rate && !$0.isReverse }, "\(rate)")
        }
    }

    func testDecodesEachRateCode() {
        for rate in FrameRate.allCases {
            var decoder = MTCDecoder()
            XCTAssertEqual(feed(&decoder, MTCEncoder.quarterFrames(fields(2, 0, 0, 0), rate: rate)).first?.frameRate, rate)
            XCTAssertEqual(decoder.receive(.systemExclusive(MTCEncoder.fullFrame(fields(2, 0, 0, 0), rate: rate)))?.frameRate, rate)
        }
    }

    func testDropFrameSkipsFramesZeroAndOne() {
        var decoder = MTCDecoder()
        let times = feed(&decoder, runningQuarterFrames(from: fields(0, 0, 59, 20), rate: .fps2997DropFrame, sets: 8))
        let index = times.firstIndex { $0.fields == fields(0, 0, 59, 29) }!
        XCTAssertEqual(times[index + 1].fields, fields(0, 1, 0, 2))
    }

    func testFullFrameReportsTheExactTime() {
        var decoder = MTCDecoder()
        let time = decoder.receive(.systemExclusive(MTCEncoder.fullFrame(fields(3, 12, 30, 5), rate: .fps30)))
        XCTAssertEqual(time, MTCTime(fields: fields(3, 12, 30, 5), frameRate: .fps30, kind: .fullFrame))
    }

    func testFullFrameAcceptsAnyDeviceID() {
        var decoder = MTCDecoder()
        XCTAssertNotNil(decoder.receive(.systemExclusive(MTCEncoder.fullFrame(fields(1, 0, 0, 0), rate: .fps25, device: 0x10))))
    }

    func testAJumpMidRunNeedsAFullFreshSetBeforeReportingAgain() {
        var decoder = MTCDecoder()
        var stream = runningQuarterFrames(from: fields(1, 0, 0, 0), rate: .fps25, sets: 3)
        // Locate: a full frame, then quarter-frames from the new place.
        let full = MTCEncoder.fullFrame(fields(5, 0, 0, 0), rate: .fps25)
        let times = feed(&decoder, stream) + [decoder.receive(.systemExclusive(full))!]
        stream = runningQuarterFrames(from: fields(5, 0, 0, 0), rate: .fps25, sets: 2)
        let after = feed(&decoder, stream)
        XCTAssertEqual(times.last?.kind, .fullFrame)
        XCTAssertEqual(after.map(\.fields), [fields(5, 0, 0, 2), fields(5, 0, 0, 3), fields(5, 0, 0, 4)])
    }

    func testAMissingQuarterFrameReportsNothingUntilAFullSetArrives() {
        var decoder = MTCDecoder()
        var stream = runningQuarterFrames(from: fields(1, 0, 0, 0), rate: .fps25, sets: 4)
        stream.remove(at: 12) // piece 4 of the second set, just after its midpoint
        let times = feed(&decoder, stream)
        // Set 1 reports and set 2's midpoint follows it; the gap breaks set 2;
        // set 3 relocks; set 4's midpoint and completion follow.
        XCTAssertEqual(times.map(\.fields), [fields(1, 0, 0, 2), fields(1, 0, 0, 3),
                                             fields(1, 0, 0, 6), fields(1, 0, 0, 7), fields(1, 0, 0, 8)])
    }

    func testDecodesReversePlayback() {
        var decoder = MTCDecoder()
        // Backwards: each set's pieces arrive 7 to 0, and time decreases by two frames per set.
        var stream: [UInt8] = []
        for set in 0..<5 {
            stream += MTCEncoder.quarterFrames(fields(1, 0, 10, 0).advanced(by: -2 * set, rate: .fps25), rate: .fps25).reversed()
        }
        let times = feed(&decoder, stream)
        XCTAssertTrue(times.allSatisfy(\.isReverse))
        XCTAssertEqual(times.first?.fields, fields(1, 0, 9, 23))
        let expected = (0..<times.count).map { fields(1, 0, 9, 23).advanced(by: -$0, rate: .fps25) }
        XCTAssertEqual(times.map(\.fields), expected)
    }

    func testIgnoresInvalidTimes() {
        var decoder = MTCDecoder()
        XCTAssertNil(decoder.receive(.systemExclusive([0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x20 | 25, 0, 0, 0, 0xF7])))
        XCTAssertNil(decoder.receive(.systemExclusive([0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x20, 0, 0, 25, 0xF7])))
        XCTAssertNil(decoder.receive(.systemExclusive([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7])))
    }

    func testDecodesThroughTheParserFromRawBytes() {
        var parser = MIDIParser()
        var decoder = MTCDecoder()
        let bytes: [UInt8] = MTCEncoder.quarterFrames(fields(1, 2, 3, 4), rate: .fps30).flatMap { [UInt8(0xF1), $0] }
        let times = parser.parse(bytes).compactMap { decoder.receive($0) }
        XCTAssertEqual(times.map(\.fields), [fields(1, 2, 3, 6)])
    }

    // MARK: Helpers

    private func fields(_ h: Int, _ m: Int, _ s: Int, _ f: Int) -> TimecodeFields {
        TimecodeFields(hours: h, minutes: m, seconds: s, frames: f)
    }

    /// Quarter-frame data bytes for `sets` consecutive two-frame sets.
    private func runningQuarterFrames(from start: TimecodeFields, rate: FrameRate, sets: Int) -> [UInt8] {
        (0..<sets).flatMap { MTCEncoder.quarterFrames(start.advanced(by: 2 * $0, rate: rate), rate: rate) }
    }

    private func feed(_ decoder: inout MTCDecoder, _ quarterFrames: [UInt8]) -> [MTCTime] {
        quarterFrames.compactMap { decoder.receive(.quarterFrame($0)) }
    }
}
