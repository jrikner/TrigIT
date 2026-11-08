// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
import TrigITEngine
import TrigITProtocols
import TrigITSpike
import TrigITStorage

final class SpikeOptionsTests: XCTestCase {
    func testDefaultsToArtNetOnly() throws {
        let options = try SpikeOptions(arguments: ["show.trigit"])
        XCTAssertEqual(options.setPath, "show.trigit")
        XCTAssertEqual(options.sources, [.artNet])
        XCTAssertEqual(options.ltcChannel, 1)
        XCTAssertEqual(options.artNetPort, 6454)
        XCTAssertNil(options.duration)
    }

    func testFirstSourceIsPrimarySecondIsBackup() throws {
        let options = try SpikeOptions(arguments: ["--source", "ltc", "show.trigit", "--source", "ArtNet",
                                                   "--ltc-device", "Focusrite", "--ltc-channel", "2",
                                                   "--report", "r.txt", "--duration", "90"])
        XCTAssertEqual(options.sources, [.ltc, .artNet])
        XCTAssertEqual(options.ltcDevice, "Focusrite")
        XCTAssertEqual(options.ltcChannel, 2)
        XCTAssertEqual(options.reportPath, "r.txt")
        XCTAssertEqual(options.duration, 90)
    }

    func testListDevicesNeedsNoSet() throws {
        XCTAssertTrue(try SpikeOptions(arguments: ["--list-devices"]).listDevices)
    }

    func testRejectsBadArguments() {
        for arguments in [[], ["a.trigit", "b.trigit"], ["a.trigit", "--source", "mtc"],
                          ["a.trigit", "--source", "ltc", "--source", "ltc"], ["a.trigit", "--ltc-channel", "0"],
                          ["a.trigit", "--artnet-port", "70000"], ["a.trigit", "--duration"], ["a.trigit", "--bogus"]] {
            XCTAssertThrowsError(try SpikeOptions(arguments: arguments), "\(arguments)")
        }
    }
}

final class SpikeSessionTests: XCTestCase {
    let resolume = Destination(name: "Resolume", host: "127.0.0.1", port: 7000)
    lazy var launch = OSCMessage(address: "/composition/columns/1/connect", arguments: [.int(1)])
    lazy var intro = Song(name: "Intro", start: Timecode("00:01:00:00")!, end: Timecode("00:02:00:00")!,
                          startActions: [Action(destinationID: resolume.id, message: .osc(launch))])
    lazy var set = ShowSet(name: "Test", songs: [intro], destinations: [resolume])

    func packet(_ text: String) -> [UInt8] {
        let t = Timecode(text)!
        return ArtTimeCode(fields: TimecodeFields(hours: t.hours, minutes: t.minutes, seconds: t.seconds, frames: t.frames),
                           frameRate: .fps30).packet
    }

    /// Plays 30 fps Art-Net Timecode frame by frame, sending every datagram
    /// 0.1 ms after its frame arrived. Returns the datagrams.
    func play(_ session: inout SpikeSession, from start: String, frames: Int, skipping skipped: Set<Int> = [],
              sendError: String? = nil) -> [SpikeSession.Send] {
        var sends: [SpikeSession.Send] = []
        let first = Timecode(start)!.frameIndex(at: .fps30)
        for n in 0..<frames where !skipped.contains(n) {
            let time = 10 + Double(n) / 30
            let timecode = Timecode(frameIndex: first + n, rate: .fps30)
            for send in session.receiveArtNet(packet(timecode.description), arrivedAt: time, role: .primary).sends {
                session.sent(send, at: time + 0.0001, error: sendError)
                sends.append(send)
            }
        }
        return sends
    }

    func report(_ session: SpikeSession) -> String {
        session.report(.init(computer: "test", setName: "Test", sources: "Art-Net", timer: "test", tickPeriod: 0.01), endedAt: 20)
    }

    func testPlayingIntoASongSendsItsOSCOnceOnTime() {
        var session = SpikeSession(set: set, startedAt: 10)
        let sends = play(&session, from: "00:00:59:20", frames: 30)
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.bytes, launch.encoded())
        XCTAssertEqual(sends.first?.host, "127.0.0.1")
        XCTAssertEqual(sends.first?.port, 7000)
        let text = report(session)
        XCTAssertTrue(text.contains("Songs fired: 1 (late: 0, double: 0, missed: 0)"), text)
        XCTAssertTrue(text.contains("OSC sends: 1 sent, 0 failed"), text)
        XCTAssertTrue(text.contains("29 frames") || text.contains("30 frames"), text)
        XCTAssertTrue(text.contains("ms: p50 0.10, p95 0.10, p99 0.10, max 0.10"), text)
        XCTAssertTrue(text.contains("fired Intro: 1 sent, on time"), text)
    }

    func testAMissedFrameAtTheStartMakesTheFireLate() {
        var session = SpikeSession(set: set, startedAt: 10)
        // Frame 10 is 00:01:00:00; it never arrives, so the Song fires on 00:01:00:01.
        _ = play(&session, from: "00:00:59:20", frames: 20, skipping: [10])
        let text = report(session)
        XCTAssertTrue(text.contains("Songs fired: 1 (late: 1,"), text)
        XCTAssertTrue(text.contains("1 frames late"), text)
    }

    func testFailedSendsAreCounted() {
        var session = SpikeSession(set: set, startedAt: 10)
        _ = play(&session, from: "00:00:59:20", frames: 20, sendError: "unreachable")
        XCTAssertTrue(report(session).contains("OSC sends: 0 sent, 1 failed"))
    }

    func testRestartingAfterAStopFiresAgainButIsNoDoubleFire() {
        var session = SpikeSession(set: set, startedAt: 10)
        _ = play(&session, from: "00:01:00:00", frames: 5)
        _ = session.tick(at: 20)
        let sends = play(&session, from: "00:01:00:05", frames: 5)
        XCTAssertEqual(sends.count, 1)
        XCTAssertTrue(report(session).contains("Songs fired: 2 (late: 0, double: 0, missed: 0)"))
    }

    func testNonTimecodePacketsAreIgnored() {
        var session = SpikeSession(set: set, startedAt: 10)
        XCTAssertTrue(session.receiveArtNet([1, 2, 3], arrivedAt: 10, role: .primary).sends.isEmpty)
        XCTAssertTrue(report(session).contains("not timecode: 1"))
    }

    func testFrameJitterIsTheDistanceFromTheFrameInterval() {
        var session = SpikeSession(set: set, startedAt: 10)
        // Frames 2 ms late every other frame: intervals alternate 35.3 and 31.3 ms.
        for n in 0..<11 {
            let time = 10 + Double(n) / 30 + (n % 2 == 1 ? 0.002 : 0)
            _ = session.receiveArtNet(packet(Timecode(frameIndex: n, rate: .fps30).description), arrivedAt: time, role: .primary)
        }
        XCTAssertTrue(report(session).contains("jitter (ms off the frame interval): p50 2.00, p95 2.00, p99 2.00, max 2.00"))
    }

    func testClockTickIntervals() {
        var session = SpikeSession(set: set, startedAt: 10)
        for time in [10.0, 10.010, 10.020, 10.036] { _ = session.tick(at: time) }
        XCTAssertTrue(report(session).contains("interval ms: p50 10.00, p95 16.00, p99 16.00, max 16.00"), report(session))
    }

    /// The example Set shipped with the Windows build opens and sends OSC.
    func testExampleSetOpens() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../docs/windows-spike-example.trigit").standardizedFileURL
        let set = try SetFile.read(from: url)
        XCTAssertFalse(set.songs.isEmpty)
        XCTAssertTrue(set.songs.allSatisfy { song in
            song.startActions.allSatisfy { if case .osc = $0.message { return true } else { return false } }
        })
    }
}
