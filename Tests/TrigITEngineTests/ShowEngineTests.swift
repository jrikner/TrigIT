// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import TrigITEngine
import TrigITProtocols

/// Scenario tests: a scripted timeline of readings goes in; only the events
/// that come out are checked.
final class ShowEngineTests: XCTestCase {
    let intro = Song(id: SongID(rawValue: 1), name: "Intro", start: tc("01:00:00:00"), end: tc("01:03:00:00"))
    let anthem = Song(id: SongID(rawValue: 2), name: "Anthem", start: tc("01:03:00:01"), end: tc("01:06:00:00"))
    let outro = Song(id: SongID(rawValue: 3), name: "Outro", start: tc("02:00:00:00"), end: tc("02:04:00:00"))

    var timeline: Timeline!

    override func setUp() {
        timeline = Timeline(set: ShowSet(songs: [intro, anthem, outro]))
    }

    func testPlayingIntoASongFiresItOnce() {
        timeline.play(from: "00:59:59:10", frames: 10)
        XCTAssertEqual(timeline.fired, [])
        timeline.play(frames: 50)
        XCTAssertEqual(timeline.fired, [intro.id])
    }

    func testFirstReadingInsideASongFiresIt() {
        timeline.play(from: "01:01:00:00", frames: 1)
        XCTAssertEqual(timeline.fired, [intro.id])
    }

    func testAJumpLandingInsideASongFiresIt() {
        timeline.play(from: "00:30:00:00", frames: 25)
        timeline.play(from: "02:02:10:00", frames: 25)
        XCTAssertEqual(timeline.fired, [outro.id])
        XCTAssertTrue(timeline.events.contains(.jumped(from: tc("00:30:00:24"), to: tc("02:02:10:00"))))
    }

    func testPlayingOrJumpingWithinTheSameSongDoesNotFireAgain() {
        timeline.play(from: "01:00:00:00", frames: 100)
        timeline.play(from: "01:02:00:00", frames: 25) // jump forward inside Intro
        timeline.play(from: "01:00:30:00", frames: 25) // jump back inside Intro
        XCTAssertEqual(timeline.fired, [intro.id])
        XCTAssertEqual(timeline.jumpCount, 2)
    }

    func testPlayingStraightFromOneSongIntoTheNextFiresTheNext() {
        timeline.play(from: "01:02:59:20", frames: 20)
        XCTAssertEqual(timeline.fired, [intro.id, anthem.id])
    }

    func testLeavingASongAndComingBackFiresItAgain() {
        timeline.play(from: "01:00:00:00", frames: 25)
        timeline.play(from: "01:30:00:00", frames: 25) // gap between Songs
        timeline.play(from: "01:00:10:00", frames: 25) // back into Intro
        XCTAssertEqual(timeline.fired, [intro.id, intro.id])
    }

    func testJumpingToAnotherSongAndBackFiresBoth() {
        timeline.play(from: "01:00:00:00", frames: 25)
        timeline.play(from: "02:00:00:00", frames: 25)
        timeline.play(from: "01:01:00:00", frames: 25)
        XCTAssertEqual(timeline.fired, [intro.id, outro.id, intro.id])
    }

    func testTimecodeInAGapFiresNothing() {
        timeline.play(from: "01:10:00:00", frames: 250)
        timeline.play(from: "00:00:00:00", frames: 25)
        XCTAssertEqual(timeline.fired, [])
        XCTAssertFalse(timeline.events.contains(.currentSongChanged(nil)), "never left a Song, so no change")
    }

    func testCurrentSongBecomesNilWhenLeavingIntoAGap() {
        timeline.play(from: "01:05:59:20", frames: 10)
        XCTAssertEqual(timeline.engine.currentSongID, nil)
        XCTAssertEqual(timeline.songChanges, [anthem.id, nil])
    }

    func testNaturalPlaybackIsNotAJumpAtAnyFrameRate() {
        for rate in FrameRate.allCases {
            let timeline = Timeline(set: ShowSet(), rate: rate)
            timeline.play(from: "00:09:59:00", frames: 3 * 60 * rate.nominalFramesPerSecond)
            XCTAssertEqual(timeline.jumpCount, 0, "\(rate)")
        }
    }

    func testReportsTheFrameRateAndChangesToIt() {
        timeline.play(from: "00:00:00:00", frames: 5)
        timeline.rate = .fps30
        timeline.play(frames: 5)
        XCTAssertEqual(timeline.frameRates, [.fps25, .fps30])
        XCTAssertEqual(timeline.engine.frameRate, .fps30)
    }

    func testEditingTheSetFiresNothingUntilTheNextReading() {
        timeline.play(from: "03:00:00:00", frames: 5)
        let late = Song(id: SongID(rawValue: 9), name: "Encore", start: tc("03:00:00:00"), end: tc("03:10:00:00"))
        timeline.engine.updateSet(ShowSet(songs: [late]))
        XCTAssertEqual(timeline.fired, [])
        timeline.play(frames: 1)
        XCTAssertEqual(timeline.fired, [late.id])
    }

    func testSimulatorDrivesTheEngine() {
        var simulator = Simulator(frameRate: .fps25)
        var engine = ShowEngine(set: ShowSet(songs: [intro]))
        var fired: [SongID] = []
        simulator.play(from: tc("00:59:59:00"), at: 100)
        for step in 0...100 {
            let now = 100 + Double(step) * 0.02
            if let reading = simulator.reading(at: now) {
                fired += engine.handle(reading).compactMap { if case .fired(let id, _) = $0 { return id } else { return nil } }
            }
        }
        XCTAssertEqual(fired, [intro.id])
        XCTAssertEqual(engine.currentSongID, intro.id)
    }
}

/// Feeds the engine readings at the given frame rate, one per frame, with a
/// clock that advances in step.
final class Timeline {
    var engine: ShowEngine
    var rate: FrameRate
    private(set) var events: [EngineEvent] = []
    private var now = 1_000.0
    private var position: Timecode?

    init(set: ShowSet, rate: FrameRate = .fps25, armed: Bool = false) {
        self.engine = ShowEngine(set: set, armed: armed)
        self.rate = rate
    }

    var fired: [SongID] {
        events.compactMap { if case .fired(let id, _) = $0 { return id } else { return nil } }
    }

    var ended: [EngineEvent] {
        events.filter { if case .ended = $0 { return true } else { return false } }
    }

    /// No readings for `seconds`, while the clock ticks every 10 ms.
    func silence(_ seconds: Double) {
        let end = now + seconds
        while now < end - 0.000_001 {
            now += 0.01
            events += engine.tick(at: now)
        }
    }

    /// The position `seconds` of real time after the last reading, as if
    /// playback had carried on through a gap in the signal.
    func position(after seconds: Double) -> String {
        let last = position ?? .zero
        return Timecode(frameIndex: last.frameIndex(at: rate) + Int((seconds * rate.realFramesPerSecond).rounded()),
                        rate: rate).description
    }

    func fire(_ id: SongID) { events += engine.fire(id) }
    func midi(_ message: MIDIMessage) { events += engine.handleMIDI(message) }
    func fireStop(_ id: SongID) { events += engine.fireStop(id) }
    func clearEvents() { events.removeAll() }

    var sends: [OutgoingAction] {
        events.compactMap { if case .send(let send) = $0 { return send } else { return nil } }
    }

    func setArmed(_ armed: Bool) {
        events += engine.setArmed(armed)
    }

    var jumpCount: Int {
        events.filter { if case .jumped = $0 { return true } else { return false } }.count
    }

    var songChanges: [SongID?] {
        events.compactMap { event -> SongID?? in
            if case .currentSongChanged(let id) = event { return .some(id) } else { return nil }
        }
    }

    var frameRates: [FrameRate] {
        events.compactMap { if case .frameRateChanged(let rate) = $0 { return rate } else { return nil } }
    }

    /// Plays `frames` frames, starting at `start` (a Jump if it is not the
    /// natural next frame) or continuing from the last position.
    func play(from start: String? = nil, frames: Int) {
        var index = start.map { tc($0).frameIndex(at: rate) }
            ?? position.map { $0.frameIndex(at: rate) + 1 } ?? 0
        for _ in 0..<frames {
            let timecode = Timecode(frameIndex: index, rate: rate)
            events += engine.handle(TimecodeReading(timecode: timecode, frameRate: rate, source: .simulator, timestamp: now))
            position = timecode
            index += 1
            now += 1 / rate.realFramesPerSecond
        }
    }
}

func tc(_ text: String) -> Timecode {
    guard let timecode = Timecode(text) else { fatalError("bad timecode \(text)") }
    return timecode
}
