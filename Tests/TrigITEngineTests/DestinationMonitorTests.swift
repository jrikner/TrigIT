import XCTest
import TrigITEngine

/// Destination status, through the checks the app reports and the changes returned.
final class DestinationMonitorTests: XCTestCase {
    let resolume = Destination(id: DestinationID(rawValue: 1), name: "Resolume", host: "10.0.0.20", port: 7000,
                               networkInterface: "en1", replyPort: 7001)
    let ma3MIDI = MIDIPortReference(uniqueID: 42, name: "MA3 Network MIDI")
    lazy var ma3 = Destination(id: DestinationID(rawValue: 2), name: "MA3", host: "", port: 8000, midiOutput: ma3MIDI)
    lazy var set = ShowSet(destinations: [resolume, ma3])
    var monitor = DestinationMonitor()

    @discardableResult
    func update(at time: Double, interfaces: Set<String>? = ["en0", "en1"], midi: Set<Int32> = [42]) -> [DestinationStatusChange] {
        monitor.update(set, interfaces: interfaces, midiOutputs: midi, at: time)
    }

    func status(_ destination: Destination) -> DestinationStatus? { monitor.statuses[destination.id] }

    func testUnknownUntilAPingIsAnsweredThenOnline() {
        XCTAssertTrue(update(at: 0).allSatisfy { $0.destinationID != resolume.id })
        XCTAssertEqual(status(resolume), .unknown)
        monitor.pingAnswered(resolume.id, at: 1)
        let changes = update(at: 1)
        XCTAssertEqual(changes, [DestinationStatusChange(destinationID: resolume.id, name: "Resolume", old: .unknown, new: .online)])
    }

    func testOneLostPingDoesNotFlapButSilenceGoesOfflineAndAnAnswerBringsItBack() {
        monitor.pingAnswered(resolume.id, at: 0)
        monitor.pingFailed(resolume.id, at: 2)
        XCTAssertEqual(update(at: 2.1).first { $0.destinationID == resolume.id }?.new, .online)
        monitor.pingFailed(resolume.id, at: 4)
        update(at: 4.1)
        XCTAssertEqual(status(resolume), .online)
        monitor.pingFailed(resolume.id, at: 6)
        let changes = update(at: 6.1)
        XCTAssertEqual(changes.first { $0.destinationID == resolume.id }?.new, .offline(.notResponding))
        monitor.pingAnswered(resolume.id, at: 8)
        XCTAssertEqual(update(at: 8.1).first?.new, .online)
    }

    func testNeverAnsweredIsOfflineAfterAFailedPing() {
        monitor.pingFailed(resolume.id, at: 1)
        update(at: 1)
        XCTAssertEqual(status(resolume), .offline(.notResponding))
    }

    func testAnOSCReplyMarksItOnline() {
        monitor.pingFailed(resolume.id, at: 1)
        monitor.replyReceived(onPort: 7001, from: "10.0.0.99", in: set, at: 2) // the only Destination on 7001
        update(at: 2)
        XCTAssertEqual(status(resolume), .online)
    }

    func testAReplyOnASharedPortCountsOnlyForTheSendersAddress() {
        let other = Destination(id: DestinationID(rawValue: 3), name: "Other", host: "10.0.0.30", port: 7000, replyPort: 7001)
        set.destinations.append(other)
        monitor.replyReceived(onPort: 7001, from: "10.0.0.30", in: set, at: 1)
        update(at: 1)
        XCTAssertEqual(status(other), .online)
        XCTAssertEqual(status(resolume), .unknown)
    }

    func testAMissingInterfaceIsOfflineEvenIfPingsWereAnswered() {
        monitor.pingAnswered(resolume.id, at: 0)
        update(at: 0)
        let changes = update(at: 1, interfaces: ["en0"])
        XCTAssertEqual(changes.first?.new, .offline(.interfaceMissing("en1")))
        monitor.pingAnswered(resolume.id, at: 2)
        XCTAssertEqual(update(at: 2).first?.new, .online)
    }

    func testInterfacesNotYetKnownAreNotTreatedAsMissing() {
        update(at: 0, interfaces: nil)
        XCTAssertEqual(status(resolume), .unknown)
    }

    func testAMIDIDestinationFollowsItsOutput() {
        update(at: 0)
        XCTAssertEqual(status(ma3), .online)
        let gone = update(at: 1, midi: [])
        XCTAssertEqual(gone, [DestinationStatusChange(destinationID: ma3.id, name: "MA3", old: .online,
                                                      new: .offline(.midiOutputMissing("MA3 Network MIDI")))])
        XCTAssertEqual(update(at: 2).first?.new, .online)
    }

    func testUnchangedStatusesReportNothing() {
        update(at: 0)
        XCTAssertEqual(update(at: 0.5), [])
    }

    func testDoesNotPingBroadcastMulticastOrEmptyAddresses() {
        func pings(_ host: String) -> Bool { DestinationMonitor.shouldPing(Destination(name: "", host: host, port: 1)) }
        XCTAssertTrue(pings("10.0.0.20"))
        XCTAssertTrue(pings("ma3.local"))
        XCTAssertFalse(pings("2.255.255.255"))
        XCTAssertFalse(pings("239.255.0.1"))
        XCTAssertFalse(pings(""))
    }
}
