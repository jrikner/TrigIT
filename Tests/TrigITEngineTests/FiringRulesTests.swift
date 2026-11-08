import XCTest
import TrigITEngine
import TrigITProtocols

/// Stop, Dropout, Ending, Stop Actions and manual firing.
final class FiringRulesTests: XCTestCase {
    let resolume = Destination(id: DestinationID(rawValue: 10), name: "Resolume", host: "10.0.0.20", port: 7000)

    lazy var startA = osc(1, "/song/a/start")
    lazy var stopA = osc(2, "/song/a/stop")
    lazy var startB = osc(3, "/song/b/start")
    lazy var stopB = osc(4, "/song/b/stop")

    /// Song A plays straight into Song B; Song C comes later after a gap.
    lazy var songA = Song(id: SongID(rawValue: 1), name: "A", start: tc("01:00:00:00"), end: tc("01:00:10:00"),
                          startActions: [startA], stopActions: [stopA])
    lazy var songB = Song(id: SongID(rawValue: 2), name: "B", start: tc("01:00:10:01"), end: tc("01:00:20:00"),
                          startActions: [startB], stopActions: [stopB])
    lazy var songC = Song(id: SongID(rawValue: 3), name: "C", start: tc("02:00:00:00"), end: tc("02:00:10:00"))

    func makeTimeline(armed: Bool = true, stopTime: Double = 2) -> Timeline {
        Timeline(set: ShowSet(songs: [songA, songB, songC], destinations: [resolume], stopTime: stopTime), armed: armed)
    }

    // MARK: Stop versus Dropout

    func testAGapJustUnderTheStopTimeIsADropoutAndDoesNotRefire() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:01:00", frames: 25)
        timeline.silence(1.9)
        timeline.play(from: timeline.position(after: 1.9), frames: 25)
        XCTAssertEqual(timeline.fired, [songA.id])
        XCTAssertFalse(timeline.events.contains(.stopped))
        XCTAssertTrue(timeline.events.contains { if case .dropout = $0 { return true } else { return false } })
        XCTAssertEqual(timeline.sends.map(\.action), [startA])
    }

    func testAGapJustOverTheStopTimeIsAStopAndResumingRefires() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:01:00", frames: 25)
        timeline.silence(2.1)
        XCTAssertEqual(timeline.events.filter { $0 == .stopped }.count, 1)
        XCTAssertEqual(timeline.engine.currentSongID, songA.id)
        timeline.play(frames: 25) // Ableton plays again from where it stopped
        XCTAssertEqual(timeline.fired, [songA.id, songA.id])
        XCTAssertEqual(timeline.sends.map(\.action), [startA, startA])
        XCTAssertEqual(timeline.ended, [])
    }

    func testTheStopTimeComesFromTheSet() {
        let timeline = makeTimeline(stopTime: 0.5)
        timeline.play(from: "01:00:01:00", frames: 25)
        timeline.silence(0.6)
        XCTAssertTrue(timeline.events.contains(.stopped))
    }

    func testStopTimeIsKeptWithinItsRange() {
        XCTAssertEqual(ShowSet(stopTime: 0).stopTime, ShowSet.stopTimeRange.lowerBound)
        var set = ShowSet()
        set.stopTime = 99
        XCTAssertEqual(set.stopTime, ShowSet.stopTimeRange.upperBound)
        XCTAssertEqual(ShowSet().stopTime, 2)
    }

    func testAStopIsReportedOnceAndAResumeAfterItIsNeitherAJumpNorADropout() {
        let timeline = makeTimeline()
        timeline.play(from: "00:30:00:00", frames: 25)
        timeline.silence(10)
        timeline.play(from: "00:45:00:00", frames: 25)
        XCTAssertEqual(timeline.events.filter { $0 == .stopped }.count, 1)
        XCTAssertEqual(timeline.jumpCount, 0)
        XCTAssertFalse(timeline.events.contains { if case .dropout = $0 { return true } else { return false } })
    }

    func testSilenceBeforeAnyTimecodeIsNotAStop() {
        let timeline = makeTimeline()
        timeline.silence(5)
        XCTAssertEqual(timeline.events, [])
    }

    // MARK: Ending

    func testAStopInsideASongIsNotAnEndAndTheSongStaysCurrent() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:05:00", frames: 10)
        timeline.silence(3)
        XCTAssertTrue(timeline.events.contains(.stopped))
        XCTAssertEqual(timeline.ended, [])
        XCTAssertEqual(timeline.sends.map(\.action), [startA])
        XCTAssertEqual(timeline.engine.currentSongID, songA.id)
        XCTAssertFalse(timeline.songChanges.contains(nil))
    }

    func testPlayingPastTheEndAfterAStopStillEndsTheSong() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:09:00", frames: 10)
        timeline.silence(3)
        timeline.play(frames: 30) // resumes where it stopped and plays on into B
        XCTAssertEqual(timeline.ended, [.ended(songA.id, .playedPastEnd)])
        XCTAssertEqual(timeline.sends.map(\.action), [startA, startA, stopA, startB])
    }

    func testAStopInAGapEndsNothing() {
        let timeline = makeTimeline()
        timeline.play(from: "01:30:00:00", frames: 10)
        timeline.silence(3)
        XCTAssertEqual(timeline.ended, [])
    }

    func testPlayingPastTheEndSendsStopActions() {
        let timeline = makeTimeline()
        timeline.play(from: "02:00:09:20", frames: 10) // C has no Stop Actions, so use the end into the gap
        XCTAssertTrue(timeline.events.contains(.ended(songC.id, .playedPastEnd)))
        XCTAssertEqual(timeline.engine.currentSongID, nil)
    }

    func testPlayingStraightIntoTheNextSongSendsStopActionsBeforeStartActions() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:09:20", frames: 10)
        XCTAssertEqual(timeline.sends.map(\.action), [startA, stopA, startB])
        let endedIndex = timeline.events.firstIndex(of: .ended(songA.id, .playedPastEnd))!
        let firedIndex = timeline.events.firstIndex(of: .fired(songB.id, .entering))!
        XCTAssertLessThan(endedIndex, firedIndex)
    }

    func testAJumpOutOfASongSendsNoStopActions() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:05:00", frames: 10)
        timeline.play(from: "02:00:05:00", frames: 10)
        timeline.play(from: "01:30:00:00", frames: 10)
        XCTAssertEqual(timeline.ended, [])
        XCTAssertEqual(timeline.sends.map(\.action), [startA])
    }

    func testPlayingBackwardsOutOfTheStartIsNotEnding() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:10:05", frames: 1)
        timeline.clearEvents()
        // Readings stepping back one frame per frame period: backwards playback.
        for frame in ["01:00:10:04", "01:00:10:03", "01:00:10:02", "01:00:10:01", "01:00:10:00", "01:00:09:24"] {
            timeline.play(from: frame, frames: 1)
        }
        XCTAssertFalse(timeline.ended.contains(.ended(songB.id, .playedPastEnd)))
    }

    func testResumingPastTheEndAfterAStopOnTheLastFrameEndsItExactlyOnce() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:19:15", frames: 11) // ends on 01:00:20:00, B's last frame
        XCTAssertEqual(timeline.engine.playhead, tc("01:00:20:00"))
        timeline.silence(5)
        timeline.play(from: "01:00:20:01", frames: 10) // resumes where it stopped, into the gap after B
        XCTAssertEqual(timeline.ended, [.ended(songB.id, .playedPastEnd)])
        XCTAssertEqual(timeline.sends.map(\.action), [startB, stopB])
    }

    func testResumingElsewhereAfterAStopIsNotAnEnd() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:05:00", frames: 10)
        timeline.silence(3)
        timeline.play(from: "02:00:01:00", frames: 10) // the operator relocated to C
        XCTAssertEqual(timeline.ended, [])
        XCTAssertEqual(timeline.sends.map(\.action), [startA])
        XCTAssertEqual(timeline.engine.currentSongID, songC.id)
    }

    func testResumingInTheGapAfterAStopClearsTheCurrentSongWithoutEndingIt() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:05:00", frames: 10)
        timeline.silence(3)
        timeline.play(from: "01:30:00:00", frames: 10)
        XCTAssertEqual(timeline.ended, [])
        XCTAssertNil(timeline.engine.currentSongID)
    }

    func testADropoutAcrossTheEndStillEndsTheSong() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:09:00", frames: 10)
        timeline.silence(1.5)
        timeline.play(from: timeline.position(after: 1.5), frames: 5)
        XCTAssertTrue(timeline.events.contains(.ended(songA.id, .playedPastEnd)))
        XCTAssertEqual(timeline.sends.map(\.action), [startA, stopA, startB])
    }

    func testASongEndsOnlyOncePerEntering() {
        let timeline = makeTimeline()
        timeline.play(from: "01:00:09:20", frames: 10)
        timeline.silence(3)
        timeline.silence(3)
        XCTAssertEqual(timeline.ended, [.ended(songA.id, .playedPastEnd)])
    }

    // MARK: Disarmed and manual

    func testWhileDisarmedNothingIsSentButEndingIsStillTracked() {
        let timeline = makeTimeline(armed: false)
        timeline.play(from: "01:00:09:20", frames: 10)
        timeline.silence(3)
        XCTAssertEqual(timeline.sends, [])
        XCTAssertEqual(timeline.ended, [.ended(songA.id, .playedPastEnd)])
    }

    func testManualFireSendsStartActionsEvenWhileDisarmed() {
        let timeline = makeTimeline(armed: false)
        timeline.fire(songB.id)
        XCTAssertEqual(timeline.events.first, .fired(songB.id, .manual))
        XCTAssertEqual(timeline.sends.map(\.action), [startB])
        XCTAssertEqual(timeline.sends.map(\.reason), [.manualFire])
        XCTAssertNil(timeline.engine.currentSongID, "manual firing doesn't move the current Song")
    }

    func testManualFireStopSendsStopActionsEvenWhileDisarmed() {
        let timeline = makeTimeline(armed: false)
        timeline.fireStop(songA.id)
        XCTAssertEqual(timeline.events.first, .ended(songA.id, .manual))
        XCTAssertEqual(timeline.sends.map(\.action), [stopA])
        XCTAssertEqual(timeline.sends.map(\.reason), [.manualStop])
    }

    func testManualFiringAnUnknownSongDoesNothing() {
        let timeline = makeTimeline()
        timeline.fire(SongID(rawValue: 999))
        timeline.fireStop(SongID(rawValue: 999))
        XCTAssertEqual(timeline.events, [])
    }

    func testStopActionsWithADeletedDestinationAreReported() {
        var set = ShowSet(songs: [songA], destinations: [], stopTime: 2)
        set.songs[0].startActions = []
        let timeline = Timeline(set: set, armed: true)
        timeline.play(from: "01:00:09:20", frames: 10) // plays past A's end
        XCTAssertTrue(timeline.events.contains(.missingDestination(song: songA.id, action: stopA.id)))
    }

    // MARK: Helpers

    private func osc(_ id: UInt64, _ address: String) -> Action {
        Action(id: ActionID(rawValue: id), destinationID: resolume.id, message: .osc(OSCMessage(address: address)))
    }
}
