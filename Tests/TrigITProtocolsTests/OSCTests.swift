// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import TrigITProtocols

final class OSCTests: XCTestCase {
    // Reference packets from the OSC 1.0 specification's examples.
    func testEncodesSpecExampleWithOneFloat() {
        let message = OSCMessage(address: "/oscillator/4/frequency", arguments: [.float(440.0)])
        XCTAssertEqual(hex(message.encoded()), """
            2f 6f 73 63 69 6c 6c 61 74 6f 72 2f 34 2f 66 72 \
            65 71 75 65 6e 63 79 00 2c 66 00 00 43 dc 00 00
            """)
    }

    func testEncodesSpecExampleWithMixedArguments() {
        let message = OSCMessage(address: "/foo", arguments: [
            .int(1000), .int(-1), .string("hello"), .float(1.234), .float(5.678),
        ])
        XCTAssertEqual(hex(message.encoded()), """
            2f 66 6f 6f 00 00 00 00 2c 69 69 73 66 66 00 00 \
            00 00 03 e8 ff ff ff ff 68 65 6c 6c 6f 00 00 00 \
            3f 9d f3 b6 40 b5 b2 2d
            """)
    }

    func testEncodesMessageWithoutArgumentsWithAnEmptyTypeTag() {
        let message = OSCMessage(address: "/composition/columns/3/connect")
        let bytes = message.encoded()
        XCTAssertEqual(bytes.count % 4, 0)
        // Address "/composition/columns/3/connect" is 30 bytes, padded to 32; then ",\0\0\0".
        XCTAssertEqual(Array(bytes.suffix(4)), [0x2C, 0, 0, 0])
        XCTAssertEqual(bytes.count, 36)
    }

    func testPadsStringsThatFillAWholeWordWithFourNulls() {
        let bytes = OSCMessage(address: "/abc", arguments: [.string("wxyz")]).encoded()
        XCTAssertEqual(hex(bytes), "2f 61 62 63 00 00 00 00 2c 73 00 00 77 78 79 7a 00 00 00 00")
    }

    func testValidatesAddresses() {
        XCTAssertTrue(OSCMessage(address: "/composition/layers/1/clips/2/connect").hasValidAddress)
        for bad in ["", "composition", "/with space", "/a#b", "/a,b"] {
            XCTAssertFalse(OSCMessage(address: bad).hasValidAddress, bad)
        }
    }

    func testParsesTypedArguments() {
        XCTAssertEqual(OSCArgument.parseList("1 0.5 hello -3 2.0"),
                       [.int(1), .float(0.5), .string("hello"), .int(-3), .float(2.0)])
        XCTAssertEqual(OSCArgument.parseList("  "), [])
        XCTAssertEqual(OSCArgument.parseList(#""two words" "42" "say \"hi\"""#),
                       [.string("two words"), .string("42"), .string(#"say "hi""#)])
        XCTAssertNil(OSCArgument.parseList(#""unterminated"#))
    }

    func testArgumentsRoundTripThroughTheirText() {
        let arguments: [OSCArgument] = [.int(7), .float(1.5), .float(3), .string("go"),
                                        .string("two words"), .string("42"), .string("")]
        let text = arguments.map(\.description).joined(separator: " ")
        XCTAssertEqual(OSCArgument.parseList(text), arguments)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined(separator: " ")
    }
}
