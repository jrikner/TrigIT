// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import TrigITEngine

final class SimulatorTests: XCTestCase {
    func testSendsNothingWhileStopped() {
        let simulator = Simulator(frameRate: .fps25, position: tc("01:00:00:00"))
        XCTAssertNil(simulator.reading(at: 5))
        XCTAssertEqual(simulator.position(at: 5), tc("01:00:00:00"))
    }

    func testPlaysInRealTime() {
        var simulator = Simulator(frameRate: .fps25)
        simulator.play(from: tc("01:00:00:00"), at: 10)
        XCTAssertEqual(simulator.reading(at: 10)?.timecode, tc("01:00:00:00"))
        XCTAssertEqual(simulator.reading(at: 11.5)?.timecode, tc("01:00:01:12"))
        XCTAssertEqual(simulator.reading(at: 11.5)?.source, .simulator)
    }

    func testStopHoldsThePositionAndPlayResumesFromIt() {
        var simulator = Simulator(frameRate: .fps25)
        simulator.play(from: tc("01:00:00:00"), at: 0)
        simulator.stop(at: 2)
        XCTAssertNil(simulator.reading(at: 30))
        simulator.play(at: 30)
        XCTAssertEqual(simulator.reading(at: 31)?.timecode, tc("01:00:03:00"))
    }

    func testJumpKeepsThePlayState() {
        var simulator = Simulator(frameRate: .fps30)
        simulator.play(from: .zero, at: 0)
        simulator.jump(to: tc("02:00:00:00"), at: 1)
        XCTAssertEqual(simulator.reading(at: 2)?.timecode, tc("02:00:01:00"))
        simulator.stop(at: 2)
        simulator.jump(to: tc("03:00:00:00"), at: 3)
        XCTAssertNil(simulator.reading(at: 4))
        XCTAssertEqual(simulator.position(at: 4), tc("03:00:00:00"))
    }

    func testDropFramePlaysAt2997RealFramesPerSecond() {
        var simulator = Simulator(frameRate: .fps2997DropFrame)
        simulator.play(from: .zero, at: 0)
        // One real hour of 29.97 drop-frame timecode reads one timecode hour, within a frame.
        let reading = simulator.reading(at: 3_600)!
        XCTAssertEqual(reading.timecode.frameIndex(at: .fps2997DropFrame), 107_892, accuracy: 1)
    }

    func testChangingTheFrameRateKeepsThePosition() {
        var simulator = Simulator(frameRate: .fps25, position: tc("01:00:00:10"))
        simulator.setFrameRate(.fps30, at: 0)
        XCTAssertEqual(simulator.position(at: 0), tc("01:00:00:10"))
    }
}
