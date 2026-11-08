import XCTest
import TrigITEngine
import TrigITProtocols

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
        monitor.pingAnswered(resolume.id, host: resolume.host, at: 1)
        let changes = update(at: 1)
        XCTAssertEqual(changes, [DestinationStatusChange(destinationID: resolume.id, name: "Resolume", old: .unknown, new: .online(.hostAnswers))])
    }

    func testOneLostPingDoesNotFlapButSilenceGoesOfflineAndAnAnswerBringsItBack() {
        monitor.pingAnswered(resolume.id, host: resolume.host, at: 0)
        monitor.pingFailed(resolume.id, host: resolume.host, at: 2)
        XCTAssertEqual(update(at: 2.1).first { $0.destinationID == resolume.id }?.new, .online(.hostAnswers))
        monitor.pingFailed(resolume.id, host: resolume.host, at: 4)
        update(at: 4.1)
        XCTAssertEqual(status(resolume), .online(.hostAnswers))
        monitor.pingFailed(resolume.id, host: resolume.host, at: 6)
        let changes = update(at: 6.1)
        XCTAssertEqual(changes.first { $0.destinationID == resolume.id }?.new, .offline(.notResponding))
        monitor.pingAnswered(resolume.id, host: resolume.host, at: 8)
        XCTAssertEqual(update(at: 8.1).first?.new, .online(.hostAnswers))
    }

    func testNeverAnsweredIsOfflineAfterAFailedPing() {
        monitor.pingFailed(resolume.id, host: resolume.host, at: 1)
        update(at: 1)
        XCTAssertEqual(status(resolume), .offline(.notResponding))
    }

    func testAnOSCReplyMarksItResponding() {
        monitor.pingFailed(resolume.id, host: resolume.host, at: 1)
        monitor.replyReceived(onPort: 7001, from: "10.0.0.99", in: set, at: 2) // the only Destination on 7001
        update(at: 2)
        XCTAssertEqual(status(resolume), .online(.responding))
    }

    func testAReplyOnASharedPortCountsOnlyForTheSendersAddress() {
        let other = Destination(id: DestinationID(rawValue: 3), name: "Other", host: "10.0.0.30", port: 7000, replyPort: 7001)
        set.destinations.append(other)
        monitor.replyReceived(onPort: 7001, from: "10.0.0.30", in: set, at: 1)
        update(at: 1)
        XCTAssertEqual(status(other), .online(.responding))
        XCTAssertEqual(status(resolume), .unknown)
    }

    func testAMissingInterfaceIsOfflineEvenIfPingsWereAnswered() {
        monitor.pingAnswered(resolume.id, host: resolume.host, at: 0)
        update(at: 0)
        let changes = update(at: 1, interfaces: ["en0"])
        XCTAssertEqual(changes.first?.new, .offline(.interfaceMissing("en1")))
        monitor.pingAnswered(resolume.id, host: resolume.host, at: 2)
        XCTAssertEqual(update(at: 2).first?.new, .online(.hostAnswers))
    }

    func testInterfacesNotYetKnownAreNotTreatedAsMissing() {
        update(at: 0, interfaces: nil)
        XCTAssertEqual(status(resolume), .unknown)
    }

    func testAMIDIDestinationFollowsItsOutput() {
        update(at: 0)
        XCTAssertEqual(status(ma3), .online(.midiOutputConnected))
        let gone = update(at: 1, midi: [])
        XCTAssertEqual(gone, [DestinationStatusChange(destinationID: ma3.id, name: "MA3", old: .online(.midiOutputConnected),
                                                      new: .offline(.midiOutputMissing("MA3 Network MIDI")))])
        XCTAssertEqual(update(at: 2).first?.new, .online(.midiOutputConnected))
    }

    func testUnchangedStatusesReportNothing() {
        update(at: 0)
        XCTAssertEqual(update(at: 0.5), [])
    }

    func testDoesNotPingBroadcastMulticastOrEmptyAddresses() {
        func pings(_ host: String) -> Bool { DestinationMonitor.isPingable(host) }
        XCTAssertTrue(pings("10.0.0.20"))
        XCTAssertTrue(pings("ma3.local"))
        XCTAssertFalse(pings("2.255.255.255"))
        XCTAssertFalse(pings("239.255.0.1"))
        XCTAssertFalse(pings(""))
    }

    // MARK: A send proves nothing

    func testASuccessfulSendAloneIsNeverReachable() {
        monitor.sendFinished(resolume.id, over: .osc, error: nil, at: 0)
        update(at: 0)
        XCTAssertEqual(status(resolume), .sent)
        update(at: 60)
        XCTAssertEqual(status(resolume), .sent)
    }

    func testSentThenAFailedPingIsNoReply() {
        monitor.sendFinished(resolume.id, over: .osc, error: nil, at: 0)
        monitor.pingFailed(resolume.id, host: resolume.host, at: 1)
        update(at: 1)
        XCTAssertEqual(status(resolume), .offline(.notResponding))
    }

    func testSentThenAnAnsweredPingIsReachableAndAReplyIsResponding() {
        monitor.sendFinished(resolume.id, over: .osc, error: nil, at: 0)
        monitor.pingAnswered(resolume.id, host: resolume.host, at: 0.5)
        update(at: 0.5)
        XCTAssertEqual(status(resolume), .online(.hostAnswers))
        monitor.replyReceived(onPort: 7001, from: "10.0.0.20", in: set, at: 0.8)
        update(at: 0.8)
        XCTAssertEqual(status(resolume), .online(.responding))
    }

    func testAFailedSendIsNoReplyUntilASendSucceeds() {
        monitor.pingAnswered(resolume.id, host: resolume.host, at: 0)
        monitor.sendFinished(resolume.id, over: .osc, error: "no route to host", at: 1)
        update(at: 1)
        XCTAssertEqual(status(resolume), .offline(.sendFailed("no route to host")))
        monitor.sendFinished(resolume.id, over: .osc, error: nil, at: 2)
        update(at: 2)
        XCTAssertEqual(status(resolume), .online(.hostAnswers))
    }

    func testADestinationShowsItsWorstTransport() {
        let both = Destination(id: DestinationID(rawValue: 4), name: "Both", host: "10.0.0.40", port: 8000, midiOutput: ma3MIDI)
        set.destinations = [both]
        update(at: 0)
        XCTAssertEqual(status(both), .unknown, "a MIDI output alone doesn't make an unchecked network side green")
        monitor.pingAnswered(both.id, host: both.host, at: 1)
        update(at: 1)
        XCTAssertEqual(status(both), .online(.hostAnswers))
        update(at: 2, midi: [])
        XCTAssertEqual(status(both), .offline(.midiOutputMissing("MA3 Network MIDI")))
    }

    func testAnUncheckableBroadcastDoesNotHoldAMIDIDestinationAtUnknown() {
        let both = Destination(id: DestinationID(rawValue: 5), name: "MA3", host: "2.255.255.255", port: 8000, midiOutput: ma3MIDI)
        set.destinations = [both]
        update(at: 0)
        XCTAssertEqual(status(both), .online(.midiOutputConnected))
        XCTAssertEqual(DestinationMonitor.pingTargets(of: both), [])
    }

    // MARK: Transports switched on and off

    func testAMIDIOnlyDestinationIsNeverPingedAndFollowsItsOutput() {
        let sampler = Destination(id: DestinationID(rawValue: 6), name: "Sampler", host: "10.0.0.60", port: 0,
                                  midiOutput: ma3MIDI, usesOSC: false)
        set.destinations = [sampler]
        XCTAssertEqual(DestinationMonitor.pingTargets(of: sampler), [])
        monitor.pingFailed(sampler.id, host: sampler.host, at: 0) // a stale ping from before OSC was switched off
        update(at: 0)
        XCTAssertEqual(status(sampler), .online(.midiOutputConnected))
    }

    func testOnlyTransportsSwitchedOnArePingedOnce() {
        var ma3 = Destination(name: "MA3", host: "10.0.0.30", port: 8000, dmxOutput: .artNet)
        XCTAssertEqual(DestinationMonitor.pingTargets(of: ma3), [PingTarget(host: "10.0.0.30", networkInterface: nil)])
        ma3.dmxOutput = .sACNMulticast
        ma3.usesOSC = false
        XCTAssertEqual(DestinationMonitor.pingTargets(of: ma3), [])
    }

    func testRepliesDoNotCountWhileOSCIsOff() {
        set.destinations[0].usesOSC = false
        set.destinations[0].usesMIDI = true
        set.destinations[0].midiOutput = ma3MIDI
        monitor.replyReceived(onPort: 7001, from: "10.0.0.20", in: set, at: 0)
        update(at: 0)
        XCTAssertEqual(status(resolume), .online(.midiOutputConnected))
    }

    func testDMXIsPingedAtItsOwnAddressThroughItsOwnInterface() {
        let ma3 = Destination(name: "MA3", host: "10.0.0.30", port: 8000, networkInterface: "en0", dmxOutput: .artNet,
                              dmxHost: "2.0.0.10", dmxInterface: "en5")
        XCTAssertEqual(DestinationMonitor.pingTargets(of: ma3), [PingTarget(host: "10.0.0.30", networkInterface: "en0"),
                                                                 PingTarget(host: "2.0.0.10", networkInterface: "en5")])
        set.destinations = [ma3]
        monitor.pingAnswered(ma3.id, host: "10.0.0.30", at: 0)
        update(at: 0, interfaces: ["en0", "en5"])
        XCTAssertEqual(status(ma3), .unknown, "the DMX side hasn't answered yet")
        monitor.pingAnswered(ma3.id, host: "2.0.0.10", at: 0.5)
        update(at: 0.5, interfaces: ["en0", "en5"])
        XCTAssertEqual(status(ma3), .online(.hostAnswers))
        update(at: 1, interfaces: ["en0"])
        XCTAssertEqual(status(ma3), .offline(.interfaceMissing("en5")))
    }

    func testActionsNeedTheirTransportSwitchedOn() {
        var ma3 = Destination(name: "MA3", host: "10.0.0.30", port: 8000)
        let osc = Action.Message.osc(OSCMessage(address: "/x"))
        let note = Action.Message.midiNote(MIDINote(channel: 0, note: 60))
        let pulse = Action.Message.dmxPulse(DMXPulse(universe: 1, channel: 1))
        XCTAssertEqual([osc, note, pulse].map(ma3.canCarry), [true, false, false])
        ma3[uses: .midi] = true
        ma3[uses: .dmx] = true
        ma3.usesOSC = false
        XCTAssertEqual([osc, note, pulse].map(ma3.canCarry), [false, true, true])
        XCTAssertEqual(ma3.activeDMXOutput, .artNet, "switching DMX on picks Art-Net")
    }
}
