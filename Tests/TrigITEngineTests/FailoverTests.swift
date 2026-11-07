import XCTest
import TrigITEngine
import TrigITProtocols

/// Primary/Backup failover, through readings, ticks and the events they return.
final class FailoverTests: XCTestCase {
    let resolume = Destination(id: DestinationID(rawValue: 10), name: "Resolume", host: "10.0.0.20", port: 7000)
    lazy var startA = Action(id: ActionID(rawValue: 1), destinationID: resolume.id, message: .osc(OSCMessage(address: "/a")))
    lazy var songA = Song(id: SongID(rawValue: 1), name: "A", start: tc("01:00:00:00"), end: tc("01:10:00:00"),
                          startActions: [startA])

    func makeShow() -> DualTimeline {
        DualTimeline(set: ShowSet(songs: [songA], destinations: [resolume], stopTime: 2))
    }

    func testPrimaryLostWithBackupHealthySwitchesWithoutStopDropoutOrRefiring() {
        let show = makeShow()
        show.play(from: "01:00:01:00", seconds: 2, primary: true, backup: true)
        XCTAssertEqual(show.fired, [songA.id])
        show.play(seconds: 3, primary: false, backup: true)

        XCTAssertEqual(show.liveChanges, [.backup])
        XCTAssertEqual(show.fired, [songA.id])
        XCTAssertEqual(show.sends.count, 1)
        XCTAssertFalse(show.events.contains(.stopped))
        XCTAssertFalse(show.events.contains { if case .dropout = $0 { return true } else { return false } })
        XCTAssertFalse(show.events.contains { if case .ended = $0 { return true } else { return false } })
        XCTAssertTrue(show.events.contains(.sourceHealthChanged(.primary, healthy: false)))
        XCTAssertEqual(show.alerts, [.primaryLostRunningOnBackup])
        XCTAssertEqual(show.engine.currentSongID, songA.id)
        // The Backup keeps the Playhead moving.
        XCTAssertEqual(show.engine.playhead, show.lastPosition)
    }

    func testPrimaryReturningMidSongStaysOnBackup() {
        let show = makeShow()
        show.play(from: "01:00:01:00", seconds: 2, primary: true, backup: true)
        show.play(seconds: 1, primary: false, backup: true)
        show.play(seconds: 3, primary: true, backup: true)

        XCTAssertEqual(show.liveChanges, [.backup])
        XCTAssertEqual(show.engine.liveSource, .backup)
        XCTAssertEqual(show.fired, [songA.id])
        // The Primary is back, so the alert clears even though the Backup stays live.
        XCTAssertEqual(show.alerts, [.primaryLostRunningOnBackup, nil])
    }

    func testTheNextStopReturnsToPrimary() {
        let show = makeShow()
        show.play(from: "01:00:01:00", seconds: 2, primary: true, backup: true)
        show.play(seconds: 1, primary: false, backup: true)
        show.play(seconds: 1, primary: true, backup: true)
        show.silence(3)

        XCTAssertEqual(show.events.filter { $0 == .stopped }.count, 1)
        XCTAssertEqual(show.liveChanges, [.backup, .primary])
        XCTAssertEqual(show.engine.liveSource, .primary)
        XCTAssertNil(show.engine.alert)

        // After the Stop, the Primary is followed again and the Backup ignored.
        show.clearEvents()
        show.play(from: "01:00:30:00", seconds: 1, primary: true, backup: false, backupOffsetFrames: 0)
        show.play(seconds: 1, primary: true, backup: true, backupOffsetFrames: 250)
        XCTAssertEqual(show.liveChanges, [])
        XCTAssertEqual(show.engine.playhead, show.lastPosition)
        XCTAssertEqual(show.fired, [songA.id])
    }

    func testBothResumingTogetherAfterAStopFollowsPrimaryEvenIfBackupIsFirst() {
        let show = makeShow()
        show.play(from: "01:00:01:00", seconds: 1, primary: true, backup: true)
        show.silence(3)
        show.clearEvents()
        show.play(from: "01:00:05:00", seconds: 1, primary: true, backup: true, backupFirst: true)
        XCTAssertEqual(show.liveChanges, [])
        XCTAssertEqual(show.engine.liveSource, .primary)
    }

    func testBothLostShortlyIsADropoutWithTheAllLostAlert() {
        let show = makeShow()
        show.play(from: "01:00:01:00", seconds: 2, primary: true, backup: true)
        show.silence(1)
        show.play(from: show.position(after: 1), seconds: 1, primary: true, backup: true)

        XCTAssertEqual(show.liveChanges, [])
        XCTAssertFalse(show.events.contains(.stopped))
        XCTAssertTrue(show.events.contains { if case .dropout = $0 { return true } else { return false } })
        XCTAssertEqual(show.fired, [songA.id])
        XCTAssertEqual(show.alerts, [.allTimecodeLost, nil])
    }

    func testBothLostLongerThanTheStopTimeIsAStop() {
        let show = makeShow()
        show.play(from: "01:00:01:00", seconds: 2, primary: true, backup: true)
        show.silence(3)
        XCTAssertEqual(show.events.filter { $0 == .stopped }.count, 1)
        XCTAssertEqual(show.events.filter { if case .ended = $0 { return true } else { return false } }.count, 1)
        // The alert shows while timecode is lost, then a Stop is normal and clears it.
        XCTAssertEqual(show.alerts, [.allTimecodeLost, nil])
        show.play(seconds: 1, primary: true, backup: true)
        XCTAssertEqual(show.fired, [songA.id, songA.id])
    }

    func testBackupAloneAfterBothLostTakesOverWithADropout() {
        let show = makeShow()
        show.play(from: "01:00:01:00", seconds: 2, primary: true, backup: true)
        show.silence(1)
        show.play(from: show.position(after: 1), seconds: 1, primary: false, backup: true)
        XCTAssertEqual(show.liveChanges, [.backup])
        XCTAssertFalse(show.events.contains(.stopped))
        XCTAssertTrue(show.events.contains { if case .dropout = $0 { return true } else { return false } })
        XCTAssertEqual(show.fired, [songA.id])
        XCTAssertEqual(show.alerts, [.allTimecodeLost, .primaryLostRunningOnBackup])
    }

    func testWithoutABackupLosingPrimaryIsNormalDropoutAndStop() {
        let show = makeShow()
        show.play(from: "01:00:01:00", seconds: 2, primary: true, backup: false)
        show.silence(3)
        XCTAssertEqual(show.liveChanges, [])
        XCTAssertEqual(show.events.filter { $0 == .stopped }.count, 1)
        XCTAssertEqual(show.alerts, [.allTimecodeLost, nil])
    }
}

/// Plays a Primary and a Backup source in step, one reading per frame each,
/// with the clock ticking between frames.
final class DualTimeline {
    var engine: ShowEngine
    let rate = FrameRate.fps25
    private(set) var events: [EngineEvent] = []
    private var now = 1_000.0
    private(set) var lastPosition: Timecode?

    init(set: ShowSet) {
        engine = ShowEngine(set: set, armed: true)
    }

    var fired: [SongID] { events.compactMap { if case .fired(let id, _) = $0 { return id } else { return nil } } }
    var sends: [OutgoingAction] { events.compactMap { if case .send(let s) = $0 { return s } else { return nil } } }
    var liveChanges: [SourceRole] {
        events.compactMap { if case .liveSourceChanged(let role) = $0 { return role } else { return nil } }
    }
    var alerts: [TimecodeAlert?] {
        events.compactMap { if case .alertChanged(let alert) = $0 { return .some(alert) } else { return nil } }
    }
    func clearEvents() { events.removeAll() }

    func position(after seconds: Double) -> String {
        Timecode(frameIndex: (lastPosition ?? .zero).frameIndex(at: rate) + Int((seconds * rate.realFramesPerSecond).rounded()),
                 rate: rate).description
    }

    /// Plays from `start` (or on from the last position). The Backup runs
    /// `backupOffsetFrames` ahead, to tell which source moved the Playhead.
    func play(from start: String? = nil, seconds: Double, primary: Bool, backup: Bool,
              backupOffsetFrames: Int = 0, backupFirst: Bool = false) {
        var index = start.map { tc($0).frameIndex(at: rate) } ?? lastPosition.map { $0.frameIndex(at: rate) + 1 } ?? 0
        for _ in 0..<Int(seconds * rate.realFramesPerSecond) {
            let timecode = Timecode(frameIndex: index, rate: rate)
            let backupCode = Timecode(frameIndex: index + backupOffsetFrames, rate: rate)
            func feed(_ role: SourceRole) {
                let code = role == .primary ? timecode : backupCode
                events += engine.handle(TimecodeReading(timecode: code, frameRate: rate, source: role == .primary ? .ltc : .artNet,
                                                        timestamp: now), from: role)
            }
            let order: [SourceRole] = backupFirst ? [.backup, .primary] : [.primary, .backup]
            for role in order where role == .primary ? primary : backup { feed(role) }
            lastPosition = timecode
            index += 1
            now += 0.002
            events += engine.tick(at: now)
            now += 1 / rate.realFramesPerSecond - 0.002
        }
    }

    func silence(_ seconds: Double) {
        let end = now + seconds
        while now < end - 0.000_001 {
            now += 0.01
            events += engine.tick(at: now)
        }
    }
}
