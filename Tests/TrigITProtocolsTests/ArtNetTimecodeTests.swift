// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import TrigITProtocols

final class ArtNetTimecodeTests: XCTestCase {
    /// Built byte by byte from the Art-Net 4 specification's ArtTimeCode table,
    /// independently of the encoder.
    let reference: [UInt8] = [
        0x41, 0x72, 0x74, 0x2D, 0x4E, 0x65, 0x74, 0x00, // "Art-Net\0"
        0x00, 0x97, // OpCode 0x9700, low byte first
        0x00, 0x0E, // protocol version 14, high byte first
        0x00, // Filler1
        0x00, // StreamId
        0x10, // Frames 16
        0x34, // Seconds 52
        0x25, // Minutes 37
        0x01, // Hours 1
        0x01, // Type: EBU 25 fps
    ]

    func testParsesTheReferencePacket() {
        XCTAssertEqual(ArtTimeCode(packet: reference),
                       ArtTimeCode(fields: TimecodeFields(hours: 1, minutes: 37, seconds: 52, frames: 16), frameRate: .fps25))
    }

    func testEncodesTheReferencePacket() {
        let timecode = ArtTimeCode(fields: TimecodeFields(hours: 1, minutes: 37, seconds: 52, frames: 16), frameRate: .fps25)
        XCTAssertEqual(timecode.packet, reference)
    }

    func testReadsEveryRateType() {
        let rates: [(UInt8, FrameRate)] = [(0, .fps24), (1, .fps25), (2, .fps2997DropFrame), (3, .fps30)]
        for (type, rate) in rates {
            var packet = reference
            packet[18] = type
            XCTAssertEqual(ArtTimeCode(packet: packet)?.frameRate, rate)
        }
    }

    func testReadsTheStreamID() {
        var packet = reference
        packet[13] = 3
        XCTAssertEqual(ArtTimeCode(packet: packet)?.streamID, 3)
    }

    func testAcceptsTrailingBytes() {
        XCTAssertNotNil(ArtTimeCode(packet: reference + [0, 0]))
    }

    func testRejectsMalformedPackets() {
        func modified(_ change: (inout [UInt8]) -> Void) -> [UInt8] {
            var packet = reference
            change(&packet)
            return packet
        }
        let bad: [(String, [UInt8])] = [
            ("empty", []),
            ("short", Array(reference.prefix(18))),
            ("wrong ID", modified { $0[0] = 0x61 }),
            ("ArtDmx opcode", modified { $0[9] = 0x50 }),
            ("byte-swapped opcode", modified { $0[8] = 0x97; $0[9] = 0x00 }),
            ("unknown type", modified { $0[18] = 4 }),
            ("frame 25 at 25 fps", modified { $0[14] = 25 }),
            ("seconds 60", modified { $0[15] = 60 }),
            ("hours 24", modified { $0[17] = 24 }),
            ("dropped frame number", modified { $0[18] = 2; $0[14] = 0; $0[15] = 0; $0[16] = 1 }),
        ]
        for (name, packet) in bad {
            XCTAssertNil(ArtTimeCode(packet: packet), name)
        }
    }

    func testRoundTripsEveryRate() {
        for rate in FrameRate.allCases {
            let timecode = ArtTimeCode(fields: TimecodeFields(hours: 23, minutes: 59, seconds: 59, frames: rate.nominalFramesPerSecond - 1),
                                       frameRate: rate, streamID: 7)
            XCTAssertEqual(ArtTimeCode(packet: timecode.packet), timecode)
        }
    }
}
