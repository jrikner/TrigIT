import XCTest
@testable import TrigITEngine
import TrigITProtocols

final class ShowProgressTests: XCTestCase {
    private let intro = Song(name: "Intro", start: Timecode("01:00:00:00")!, end: Timecode("01:02:00:00")!)
    private let city = Song(name: "Midnight City", start: Timecode("01:05:00:00")!, end: Timecode("01:08:00:00")!)

    func testInsideASongGivesElapsedDurationAndNextStart() {
        let set = ShowSet(name: "S", songs: [city, intro])
        let progress = ShowProgress(set: set, playhead: Timecode("01:01:04:00")!, rate: .fps25)
        XCTAssertEqual(progress.elapsed, 64)
        XCTAssertEqual(progress.duration, 120)
        XCTAssertEqual(progress.nextSongID, city.id)
        XCTAssertEqual(progress.untilNext, 236)
    }

    func testBetweenSongsHasNoElapsedButCountsDown() {
        let set = ShowSet(name: "S", songs: [intro, city])
        let progress = ShowProgress(set: set, playhead: Timecode("01:04:59:00")!, rate: .fps25)
        XCTAssertNil(progress.elapsed)
        XCTAssertEqual(progress.untilNext, 1)
    }

    func testAfterTheLastSongThereIsNoNext() {
        let set = ShowSet(name: "S", songs: [intro])
        let progress = ShowProgress(set: set, playhead: Timecode("02:00:00:00")!, rate: .fps25)
        XCTAssertNil(progress.nextSongID)
        XCTAssertNil(progress.untilNext)
    }

    func testChangeSummary() {
        let old = ShowSet(name: "S", songs: [intro])
        XCTAssertEqual(SetChangeSummary.describe(from: nil, to: old), "Opened")
        XCTAssertEqual(SetChangeSummary.describe(from: old, to: old), "No changes")

        var moved = intro
        moved.start = Timecode("01:00:10:00")!
        moved.startActions = [Action(destinationID: DestinationID(), message: .osc(OSCMessage(address: "/a")))]
        let new = ShowSet(id: old.id, name: "S", songs: [moved, city])
        XCTAssertEqual(SetChangeSummary.describe(from: old, to: new),
                       "Added Midnight City, moved the start of Intro, added an Action")
    }
}
