import XCTest
import TrigITEngine

final class TimecodeTests: XCTestCase {
    func testParsesAndFormats() throws {
        let tc = try XCTUnwrap(Timecode("01:02:03:04"))
        XCTAssertEqual([tc.hours, tc.minutes, tc.seconds, tc.frames], [1, 2, 3, 4])
        XCTAssertEqual(tc.description, "01:02:03:04")
        XCTAssertEqual(Timecode(" 1:2:3;4 ")?.description, "01:02:03:04")
    }

    func testRejectsInvalidText() {
        for text in ["", "01:02:03", "01:02:03:04:05", "24:00:00:00", "00:60:00:00",
                     "00:00:60:00", "00:00:00:30", "aa:bb:cc:dd", "001:00:00:00", "-1:00:00:00"] {
            XCTAssertNil(Timecode(text), text)
        }
    }

    func testOrdersByFields() {
        XCTAssertLessThan(Timecode("00:59:59:29")!, Timecode("01:00:00:00")!)
        XCTAssertLessThan(Timecode("01:00:00:00")!, Timecode("01:00:00:01")!)
    }

    func testFrameIndexRoundTripsForEveryFrameOfTheFirstTwoHours() {
        for rate in FrameRate.allCases {
            let frames = rate.isDropFrame ? 2 * 6 * 17_982 : 2 * 3_600 * rate.nominalFramesPerSecond
            for index in 0..<frames {
                let tc = Timecode(frameIndex: index, rate: rate)
                XCTAssertEqual(tc.frameIndex(at: rate), index, "\(rate) \(tc)")
            }
        }
    }

    func testDropFrameSkipsFramesZeroAndOneExceptEveryTenthMinute() {
        let rate = FrameRate.fps2997DropFrame
        let lastOfMinute0 = Timecode("00:00:59:29")!.frameIndex(at: rate)
        XCTAssertEqual(Timecode(frameIndex: lastOfMinute0 + 1, rate: rate).description, "00:01:00:02")
        let lastOfMinute9 = Timecode("00:09:59:29")!.frameIndex(at: rate)
        XCTAssertEqual(Timecode(frameIndex: lastOfMinute9 + 1, rate: rate).description, "00:10:00:00")
        // One hour of 29.97 drop-frame is 107,892 frames.
        XCTAssertEqual(Timecode("01:00:00:00")!.frameIndex(at: rate), 107_892)
    }

    func testWrapsAtTwentyFourHours() {
        XCTAssertEqual(Timecode(frameIndex: 24 * 3_600 * 25, rate: .fps25), .zero)
        XCTAssertEqual(Timecode(frameIndex: -1, rate: .fps25).description, "23:59:59:24")
    }
}
