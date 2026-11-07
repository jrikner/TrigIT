import XCTest
import TrigITEngine
import TrigITProtocols

/// After TrigIT is relaunched (say, after a crash mid-Song), a fresh engine
/// treats the first reading inside a Song as Entering it, so that Song's
/// Start Actions go out once more and the devices are back in sync.
final class RelaunchTests: XCTestCase {
    let resolume = Destination(id: DestinationID(rawValue: 10), name: "Resolume", host: "10.0.0.20", port: 7000)
    lazy var start = Action(id: ActionID(rawValue: 1), destinationID: resolume.id, message: .osc(OSCMessage(address: "/a/start")))
    lazy var song = Song(id: SongID(rawValue: 1), name: "A", start: Timecode("01:00:00:00")!, end: Timecode("01:05:00:00")!,
                         startActions: [start])

    func testTheFirstReadingAfterLaunchInsideASongEntersIt() {
        // A Song already playing for two minutes when the relaunched app hears timecode.
        let timeline = Timeline(set: ShowSet(songs: [song], destinations: [resolume]), armed: true)
        timeline.play(from: "01:02:00:00", frames: 25)
        XCTAssertEqual(timeline.events.compactMap { if case .fired(let id, let cause) = $0 { return cause == .entering ? id : nil } else { return nil } },
                       [song.id])
        XCTAssertEqual(timeline.sends.map(\.action), [start])
        XCTAssertEqual(timeline.sends.map(\.reason), [.entering])
    }

    func testTheFirstReadingAfterLaunchOutsideEverySongFiresNothing() {
        let timeline = Timeline(set: ShowSet(songs: [song], destinations: [resolume]), armed: true)
        timeline.play(from: "00:59:00:00", frames: 25)
        XCTAssertEqual(timeline.fired, [])
    }
}
