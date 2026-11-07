import XCTest
import TrigITEngine
import TrigITProtocols

/// Entering a Song sends its Start Actions to their Destinations, in order,
/// only while Armed.
final class SendingTests: XCTestCase {
    let resolume = Destination(id: DestinationID(rawValue: 10), name: "Resolume", host: "10.0.0.20", port: 7000, networkInterface: "en1")
    let ma3 = Destination(id: DestinationID(rawValue: 11), name: "MA3", host: "10.0.0.30", port: 8000)

    lazy var launchColumn = Action(id: ActionID(rawValue: 100), destinationID: resolume.id,
                                   message: .osc(OSCMessage(address: "/composition/columns/3/connect", arguments: [.int(1)])))
    lazy var goExecutor = Action(id: ActionID(rawValue: 101), destinationID: ma3.id,
                                 message: .osc(OSCMessage(address: "/cmd", arguments: [.string("Go+ Exec 201")])))
    lazy var intro = Song(id: SongID(rawValue: 1), name: "Intro", start: tc("01:00:00:00"), end: tc("01:03:00:00"),
                          startActions: [launchColumn, goExecutor])
    lazy var set = ShowSet(songs: [intro], destinations: [resolume, ma3])

    func testArmedEnteringSendsStartActionsInOrderToTheirDestinations() {
        let timeline = Timeline(set: set, armed: true)
        timeline.play(from: "00:59:59:20", frames: 10)
        XCTAssertEqual(timeline.sends, [
            OutgoingAction(songID: intro.id, action: launchColumn, destination: resolume, reason: .entering),
            OutgoingAction(songID: intro.id, action: goExecutor, destination: ma3, reason: .entering),
        ])
    }

    func testSendsFollowTheFiringEvent() {
        let timeline = Timeline(set: set, armed: true)
        timeline.play(from: "01:00:00:00", frames: 1)
        let firedIndex = timeline.events.firstIndex(of: .fired(intro.id, .entering))
        let firstSendIndex = timeline.events.firstIndex { if case .send = $0 { return true } else { return false } }
        XCTAssertNotNil(firedIndex)
        XCTAssertLessThan(firedIndex!, firstSendIndex!)
    }

    func testStayingInTheSongSendsNothingMore() {
        let timeline = Timeline(set: set, armed: true)
        timeline.play(from: "01:00:00:00", frames: 250)
        timeline.play(from: "01:02:00:00", frames: 25)
        XCTAssertEqual(timeline.sends.count, 2)
    }

    func testDisarmedSendsNothingButStillTracksTheSong() {
        let timeline = Timeline(set: set, armed: false)
        timeline.play(from: "01:00:00:00", frames: 25)
        XCTAssertEqual(timeline.sends, [])
        XCTAssertEqual(timeline.fired, [intro.id])
        XCTAssertEqual(timeline.engine.currentSongID, intro.id)
    }

    func testArmingMidSongDoesNotSendRetroactively() {
        let timeline = Timeline(set: set, armed: false)
        timeline.play(from: "01:00:00:00", frames: 25)
        timeline.setArmed(true)
        timeline.play(frames: 25)
        XCTAssertEqual(timeline.sends, [])
        XCTAssertTrue(timeline.events.contains(.armedChanged(true)))
    }

    func testArmingTwiceReportsOnce() {
        var engine = ShowEngine(set: set)
        XCTAssertEqual(engine.setArmed(true), [.armedChanged(true)])
        XCTAssertEqual(engine.setArmed(true), [])
        XCTAssertEqual(engine.setArmed(false), [.armedChanged(false)])
    }

    func testAnActionWhoseDestinationWasDeletedIsReportedNotSent() {
        var withoutMA3 = set
        withoutMA3.destinations.removeAll { $0.id == ma3.id }
        let timeline = Timeline(set: withoutMA3, armed: true)
        timeline.play(from: "01:00:00:00", frames: 1)
        XCTAssertEqual(timeline.sends.map(\.action), [launchColumn])
        XCTAssertTrue(timeline.events.contains(.missingDestination(song: intro.id, action: goExecutor.id)))
    }

    func testUpdatedDestinationIsUsedForTheNextSend() {
        let timeline = Timeline(set: set, armed: true)
        var moved = set
        moved.destinations[0].host = "10.0.0.99"
        timeline.engine.updateSet(moved)
        timeline.play(from: "01:00:00:00", frames: 1)
        XCTAssertEqual(timeline.sends.first?.destination.host, "10.0.0.99")
    }

    func testTheSetKnowsWhichDestinationsAreInUse() {
        XCTAssertTrue(set.isInUse(resolume.id))
        XCTAssertFalse(ShowSet(destinations: [resolume]).isInUse(resolume.id))
    }
}
