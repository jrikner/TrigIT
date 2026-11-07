import XCTest
import TrigITProtocols

/// Reference packets come from two independent open-source implementations:
/// the Python `sacn` library (1.11.0) and `stupidArtnet` (1.6.0). Each was given
/// the same slots: channel 1 = 255, channel 100 = 128, channel 512 = 17.
final class DMXPacketTests: XCTestCase {
    let slots: [UInt8] = {
        var data = [UInt8](repeating: 0, count: 512)
        data[0] = 255
        data[99] = 128
        data[511] = 17
        return data
    }()

    func testArtDmxMatchesStupidArtnet() {
        // StupidArtnet(universe=300, packet_size=512), sequence 42: the 18-byte header.
        let header = bytes("4172742d4e6574000050000e2a002c010200")
        let packet = ArtDmxPacket(portAddress: 300, sequence: 42, data: slots)
        XCTAssertEqual(packet.encoded, header + slots)
        XCTAssertEqual(packet.encoded.count, 530)
    }

    func testSACNMatchesTheSacnLibrary() {
        // DataPacket(cid=0...15, sourceName="TrigIT", universe=7, priority=100, sequence=42): 126-byte header.
        let header = bytes("""
            001000004153432d45312e3137000000726e00000004000102030405060708090a0b0c0d0e0f\
            7258000000025472696749540000000000000000000000000000000000000000000000000000\
            00000000000000000000000000000000000000000000000000000000000000006400002a0000\
            07720b02a100000001020100
            """)
        let packet = SACNDataPacket(cid: Array(0...15), sourceName: "TrigIT", universe: 7, sequence: 42, data: slots)
        XCTAssertEqual(packet.encoded, header + slots)
        XCTAssertEqual(packet.encoded.count, 638)
    }

    func testArtDmxPadsShortDataToAnEvenLengthOfAtLeastTwo() {
        XCTAssertEqual(Array(ArtDmxPacket(portAddress: 0, sequence: 1, data: [9]).encoded.suffix(4)), [0x00, 0x02, 9, 0])
        XCTAssertEqual(Array(ArtDmxPacket(portAddress: 0, sequence: 1, data: [1, 2, 3]).encoded[16..<18]), [0x00, 0x04])
    }

    func testArtDmxSplitsThePortAddressIntoSubUniAndNet() {
        let encoded = ArtDmxPacket(portAddress: 0x7ABC, sequence: 1, data: []).encoded
        XCTAssertEqual(Array(encoded[14..<16]), [0xBC, 0x7A])
    }

    func testSACNLengthsFollowTheSlotCount() {
        let encoded = SACNDataPacket(cid: [], sourceName: "x", universe: 1, sequence: 0, data: [1, 2]).encoded
        XCTAssertEqual(encoded.count, 128)
        XCTAssertEqual(Array(encoded[16..<18]), [0x70, 112]) // root: 128 - 16
        XCTAssertEqual(Array(encoded[38..<40]), [0x70, 90]) // framing: 128 - 38
        XCTAssertEqual(Array(encoded[115..<117]), [0x70, 13]) // DMP: 128 - 115
        XCTAssertEqual(Array(encoded[123..<125]), [0x00, 0x03]) // start code + 2 slots
    }

    func testSACNTruncatesLongSourceNamesAndKeepsANullTerminator() {
        let encoded = SACNDataPacket(cid: [], sourceName: String(repeating: "a", count: 100), universe: 1, sequence: 0, data: []).encoded
        XCTAssertEqual(encoded[44 + 62], UInt8(ascii: "a"))
        XCTAssertEqual(encoded[44 + 63], 0)
    }

    func testSACNMulticastAddresses() {
        XCTAssertEqual(SACNDataPacket.multicastAddress(universe: 1), "239.255.0.1")
        XCTAssertEqual(SACNDataPacket.multicastAddress(universe: 300), "239.255.1.44")
        XCTAssertEqual(SACNDataPacket.multicastAddress(universe: 63_999), "239.255.249.255")
    }

    private func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex)
        return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
    }
}

final class DMXPulseMixerTests: XCTestCase {
    func testAPulseHoldsItsValueForItsDurationThenReturnsToZero() {
        var mixer = DMXPulseMixer<Int>()
        mixer.start(DMXPulse(universe: 1, channel: 10, value: 255, duration: 0.5), in: 1, at: 100)
        XCTAssertEqual(mixer.levels(1, at: 100)[9], 255)
        XCTAssertEqual(mixer.levels(1, at: 100.49)[9], 255)
        XCTAssertEqual(mixer.levels(1, at: 100.5)[9], 0)
        XCTAssertEqual(mixer.levels(1, at: 101), [UInt8](repeating: 0, count: 512))
    }

    func testPulsesOnDifferentChannelsDoNotInterfere() {
        var mixer = DMXPulseMixer<Int>()
        mixer.start(DMXPulse(universe: 1, channel: 1, value: 255, duration: 1), in: 1, at: 0)
        mixer.start(DMXPulse(universe: 1, channel: 2, value: 100, duration: 0.2), in: 1, at: 0.5)
        let during = mixer.levels(1, at: 0.6)
        XCTAssertEqual(Array(during.prefix(2)), [255, 100])
        let after = mixer.levels(1, at: 0.8)
        XCTAssertEqual(Array(after.prefix(2)), [255, 0], "the second pulse ending leaves the first alone")
        XCTAssertEqual(Array(mixer.levels(1, at: 1.1).prefix(2)), [0, 0])
    }

    func testOverlappingPulsesOnOneChannelTakeTheHighestValue() {
        var mixer = DMXPulseMixer<Int>()
        mixer.start(DMXPulse(universe: 1, channel: 5, value: 100, duration: 1), in: 1, at: 0)
        mixer.start(DMXPulse(universe: 1, channel: 5, value: 200, duration: 0.3), in: 1, at: 0.2)
        XCTAssertEqual(mixer.levels(1, at: 0.3)[4], 200)
        XCTAssertEqual(mixer.levels(1, at: 0.6)[4], 100)
        XCTAssertEqual(mixer.levels(1, at: 1.0)[4], 0)
    }

    func testUniversesAreIndependent() {
        var mixer = DMXPulseMixer<String>()
        mixer.start(DMXPulse(universe: 1, channel: 1, value: 255), in: "A", at: 0)
        XCTAssertEqual(mixer.levels("B", at: 0.1)[0], 0)
        XCTAssertEqual(mixer.levels("A", at: 0.1)[0], 255)
    }

    func testReportsWhenTheNextPulseEnds() {
        var mixer = DMXPulseMixer<Int>()
        XCTAssertNil(mixer.nextEnd(after: 0))
        mixer.start(DMXPulse(universe: 1, channel: 1, duration: 0.5), in: 1, at: 0)
        mixer.start(DMXPulse(universe: 1, channel: 2, duration: 0.2), in: 2, at: 0)
        XCTAssertEqual(mixer.nextEnd(after: 0), 0.2)
        XCTAssertEqual(mixer.nextEnd(after: 0.2), 0.5)
        XCTAssertNil(mixer.nextEnd(after: 0.5))
    }

    func testPulseValuesAreClamped() {
        XCTAssertEqual(DMXPulse(universe: 0, channel: 0).channel, 1)
        XCTAssertEqual(DMXPulse(universe: 0, channel: 600).channel, 512)
        XCTAssertEqual(DMXPulse(universe: 0, channel: 1, duration: 0).duration, DMXPulse.durationRange.lowerBound)
        XCTAssertEqual(DMXPulse(universe: 0, channel: 1).value, 255)
        XCTAssertEqual(DMXPulse(universe: 0, channel: 1).duration, 0.5)
    }
}
