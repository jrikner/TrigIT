import Foundation
import XCTest
import TrigITProtocols

final class LTCTests: XCTestCase {
    // MARK: Reference recordings from libltc

    func testDecodesLibltcRecordingsAtEveryFrameRate() throws {
        let cases: [(file: String, rate: FrameRate, start: [Int], frames: Int)] = [
            ("libltc-24fps-01-00-58-00", .fps24, [1, 0, 58, 0], 72),
            ("libltc-25fps-01-00-58-00", .fps25, [1, 0, 58, 0], 75),
            ("libltc-2997df-00-00-58-00", .fps2997DropFrame, [0, 0, 58, 0], 90),
            ("libltc-30fps-23-59-59-00", .fps30, [23, 59, 59, 0], 60),
        ]
        for testCase in cases {
            let samples = try loadFixture(testCase.file)
            var decoder = LTCDecoder(sampleRate: 48_000)
            let frames = decoder.decode(samples)
            let expected = Array(sequence(from: testCase.start, rate: testCase.rate).prefix(testCase.frames))

            // The first word may be lost while the decoder locks on, and the
            // last can't complete because no following frame marks the end of
            // its final bit. Every other frame must come out, in order, exactly
            // as encoded.
            assertUnbrokenRun(frames, of: expected, minimum: testCase.frames - 2, testCase.file)
            XCTAssertEqual(frames.last?.frameRate, testCase.rate, testCase.file)
            XCTAssertTrue(frames.allSatisfy { !$0.isReverse }, testCase.file)
        }
    }

    func testDropFrameRecordingSkipsFramesZeroAndOne() throws {
        var decoder = LTCDecoder(sampleRate: 48_000)
        let frames = decoder.decode(try loadFixture("libltc-2997df-00-00-58-00"))
        let index = try XCTUnwrap(frames.firstIndex { $0.fields == [0, 0, 59, 29] })
        XCTAssertEqual(frames[index + 1].fields, [0, 1, 0, 2])
        XCTAssertTrue(frames.allSatisfy(\.isDropFrame))
    }

    func testFrameStartsAreOneFrameApart() throws {
        var decoder = LTCDecoder(sampleRate: 48_000)
        let frames = decoder.decode(try loadFixture("libltc-25fps-01-00-58-00"))
        for (previous, next) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(Double(next.startSample - previous.startSample), 48_000 / 25, accuracy: 2)
        }
    }

    // MARK: Generated signals

    func testDecodesEveryRateAtCommonSampleRates() {
        for rate in FrameRate.allCases {
            for sampleRate in [44_100.0, 48_000, 96_000] {
                let start = [10, 0, 58, 0]
                let signal = LTCSignal(rate: rate, sampleRate: sampleRate).samples(from: start, frames: 3 * rate.nominalFramesPerSecond)
                var decoder = LTCDecoder(sampleRate: sampleRate)
                let frames = decoder.decode(signal)
                assertContinuous(frames, from: start, rate: rate, count: 3 * rate.nominalFramesPerSecond, "\(rate) @ \(sampleRate)")
                XCTAssertEqual(frames.last?.frameRate, rate, "\(rate) @ \(sampleRate)")
            }
        }
    }

    func testReversedPolarityDecodesTheSame() {
        var signal = LTCSignal(rate: .fps25)
        signal.invertPolarity = true
        var decoder = LTCDecoder(sampleRate: 48_000)
        assertContinuous(decoder.decode(signal.samples(from: [1, 0, 0, 0], frames: 50)), from: [1, 0, 0, 0], rate: .fps25, count: 50)
    }

    func testDecodesThroughNoiseAndDCOffset() {
        var signal = LTCSignal(rate: .fps30)
        signal.noise = 0.25 // noise peaks at a quarter of the signal level
        signal.dcOffset = 0.2
        var decoder = LTCDecoder(sampleRate: 48_000)
        assertContinuous(decoder.decode(signal.samples(from: [2, 0, 0, 0], frames: 90)), from: [2, 0, 0, 0], rate: .fps30, count: 90)
    }

    func testDecodesQuietSignals() {
        var signal = LTCSignal(rate: .fps25)
        signal.amplitude = 0.02 // about -34 dBFS
        var decoder = LTCDecoder(sampleRate: 48_000)
        assertContinuous(decoder.decode(signal.samples(from: [1, 0, 0, 0], frames: 50)), from: [1, 0, 0, 0], rate: .fps25, count: 50)
    }

    func testFollowsSpeedVariationAndKeepsTheRate() {
        for speed in [0.9, 0.95, 1.05, 1.1] {
            var signal = LTCSignal(rate: .fps24)
            signal.speed = { _ in speed }
            var decoder = LTCDecoder(sampleRate: 48_000)
            let frames = decoder.decode(signal.samples(from: [1, 0, 58, 0], frames: 72))
            assertContinuous(frames, from: [1, 0, 58, 0], rate: .fps24, count: 72, "speed \(speed)")
            XCTAssertEqual(frames.last?.frameRate, .fps24, "speed \(speed)")
        }
    }

    func testFollowsDriftingSpeed() {
        var signal = LTCSignal(rate: .fps25)
        // Speed wanders between 0.92 and 1.08 over each second, like a varispeed tape.
        signal.speed = { frame in 1 + 0.08 * sin(Double(frame) / 25 * 2 * .pi) }
        var decoder = LTCDecoder(sampleRate: 48_000)
        assertContinuous(decoder.decode(signal.samples(from: [3, 0, 0, 0], frames: 125)), from: [3, 0, 0, 0], rate: .fps25, count: 125)
    }

    func testDecodesBackwardsPlayback() {
        let forward = LTCSignal(rate: .fps25).samples(from: [1, 0, 10, 0], frames: 50)
        var decoder = LTCDecoder(sampleRate: 48_000)
        let frames = decoder.decode(forward.reversed())
        XCTAssertTrue(frames.allSatisfy(\.isReverse))
        let backwards = Array(Array(sequence(from: [1, 0, 10, 0], rate: .fps25).prefix(50)).reversed())
        assertUnbrokenRun(frames, of: backwards, minimum: 48)
    }

    func testStreamingInOddBlockSizesGivesTheSameFrames() {
        let signal = LTCSignal(rate: .fps2997DropFrame).samples(from: [0, 9, 59, 0], frames: 60)
        var whole = LTCDecoder(sampleRate: 48_000)
        let expected = whole.decode(signal)
        var streaming = LTCDecoder(sampleRate: 48_000)
        var frames: [LTCFrame] = []
        var index = 0
        var blockSizes = [1, 7, 64, 333, 512, 1_000].makeIterator()
        while index < signal.count {
            let size = blockSizes.next() ?? 256
            frames += streaming.decode(Array(signal[index..<min(index + size, signal.count)]))
            index += size
        }
        XCTAssertEqual(frames, expected)
    }

    func testRecoversAfterADropout() {
        let signal = LTCSignal(rate: .fps25)
        let before = signal.samples(from: [1, 0, 0, 0], frames: 25)
        let silence = [Float](repeating: 0, count: 24_000)
        let after = signal.samples(from: [1, 0, 1, 12], frames: 25)
        var decoder = LTCDecoder(sampleRate: 48_000)
        let frames = decoder.decode(before + silence + after)
        // The first burst loses its first frame while locking on and its last
        // because nothing follows it. The second burst's first frame comes
        // through only if the signal resumes at the opposite level; its last is
        // lost too. Everything else in both bursts must come through in order.
        let firstBurst = Array(sequence(from: [1, 0, 0, 1], rate: .fps25).prefix(23))
        XCTAssertEqual(Array(frames.prefix(23)).map(\.fields), firstBurst)
        let secondBurst = Array(sequence(from: [1, 0, 1, 12], rate: .fps25).prefix(24))
        assertUnbrokenRun(Array(frames.dropFirst(23)), of: secondBurst, minimum: 23)
        XCTAssertEqual(frames.last?.fields, [1, 0, 2, 10])
    }

    func testSilenceAndNoiseAloneDecodeNothing() {
        var decoder = LTCDecoder(sampleRate: 48_000)
        XCTAssertEqual(decoder.decode([Float](repeating: 0, count: 48_000)), [])
        var random = SeededRandom(seed: 7)
        let noise = (0..<48_000).map { _ in Float(random.next() * 0.5 - 0.25) }
        XCTAssertEqual(decoder.decode(noise), [])
    }

    func testDetectsTwentyFourVersusTwentyFiveFromTheFirstSecondRollover() {
        // Frames that never pass 23 can't prove 25 fps until a rollover, so a
        // 25 fps signal running fast enough to look like 24 must still be called
        // 25 once it rolls over from frame 24.
        var signal = LTCSignal(rate: .fps25)
        signal.speed = { _ in 0.96 } // 25 × 0.96 = 24 frames per real second
        var decoder = LTCDecoder(sampleRate: 48_000)
        let frames = decoder.decode(signal.samples(from: [1, 0, 0, 0], frames: 30))
        XCTAssertEqual(frames.last?.frameRate, .fps25)
    }

    // MARK: Helpers

    private func loadFixture(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "u8", subdirectory: "Fixtures"))
        return try Data(contentsOf: url).map { (Float($0) - 128) / 128 }
    }

    /// A signal of `count` frames must decode to at least `count - 2` of them
    /// (see the libltc test for why), with no frame missing or out of place.
    private func assertContinuous(_ frames: [LTCFrame], from start: [Int], rate: FrameRate, count: Int,
                                  _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let expected = Array(sequence(from: start, rate: rate).prefix(count))
        assertUnbrokenRun(frames, of: expected, minimum: count - 2, message, file: file, line: line)
    }

    private func assertUnbrokenRun(_ frames: [LTCFrame], of expected: [[Int]], minimum: Int,
                                   _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(frames.count, minimum, message, file: file, line: line)
        guard let first = frames.first, let offset = expected.firstIndex(of: first.fields) else {
            return XCTFail("first frame \(frames.first?.fields ?? []) not expected. \(message)", file: file, line: line)
        }
        XCTAssertEqual(frames.map(\.fields), Array(expected[offset..<min(offset + frames.count, expected.count)]),
                       message, file: file, line: line)
    }
}

/// Successive timecodes at `rate`, wrapping at midnight and skipping
/// drop-frame numbers.
func sequence(from start: [Int], rate: FrameRate) -> UnfoldSequence<[Int], [Int]> {
    Swift.sequence(state: start) { current in
        let value = current
        var (h, m, s, f) = (current[0], current[1], current[2], current[3] + 1)
        if f == rate.nominalFramesPerSecond { f = 0; s += 1 }
        if s == 60 { s = 0; m += 1 }
        if m == 60 { m = 0; h += 1 }
        if h == 24 { h = 0 }
        if rate.isDropFrame, s == 0, f < 2, m % 10 != 0 { f = 2 }
        current = [h, m, s, f]
        return value
    }
}

/// A synthetic LTC signal: biphase-mark coded words with a finite rise time,
/// and optional noise, DC offset, polarity inversion and speed changes.
struct LTCSignal {
    var rate: FrameRate
    var sampleRate = 48_000.0
    var amplitude: Float = 0.5
    var noise: Float = 0
    var dcOffset: Float = 0
    var invertPolarity = false
    /// Playback speed for each frame (1 = normal).
    var speed: (Int) -> Double = { _ in 1 }

    init(rate: FrameRate, sampleRate: Double = 48_000) {
        self.rate = rate
        self.sampleRate = sampleRate
    }

    func samples(from start: [Int], frames: Int) -> [Float] {
        var transitions: [Double] = []
        var time = 0.0
        for (index, fields) in sequence(from: start, rate: rate).prefix(frames).enumerated() {
            let bitLength = sampleRate / (80 * rate.realFramesPerSecond) / speed(index)
            for bit in word(fields) {
                transitions.append(time)
                if bit == 1 { transitions.append(time + bitLength / 2) }
                time += bitLength
            }
        }
        transitions.append(time)

        var output: [Float] = []
        output.reserveCapacity(Int(time) + 1)
        var level: Float = invertPolarity ? amplitude : -amplitude
        var smoothed = level
        var next = 0
        var random = SeededRandom(seed: 42)
        // One-pole low-pass: about a 40 µs rise time, as on real LTC.
        let alpha = Float(1 - exp(-1 / (sampleRate * 0.000_02)))
        for n in 0..<Int(time) {
            while next < transitions.count, transitions[next] <= Double(n) {
                level = -level
                next += 1
            }
            smoothed += alpha * (level - smoothed)
            output.append(smoothed + dcOffset + noise * amplitude * Float(random.next() * 2 - 1))
        }
        return output
    }

    private func word(_ fields: [Int]) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: 80)
        func put(_ value: Int, at from: Int, count: Int) {
            for i in 0..<count { bits[from + i] = UInt8(value >> i & 1) }
        }
        put(fields[3] % 10, at: 0, count: 4)
        put(fields[3] / 10, at: 8, count: 2)
        bits[10] = rate.isDropFrame ? 1 : 0
        put(fields[2] % 10, at: 16, count: 4)
        put(fields[2] / 10, at: 24, count: 3)
        put(fields[1] % 10, at: 32, count: 4)
        put(fields[1] / 10, at: 40, count: 3)
        put(fields[0] % 10, at: 48, count: 4)
        put(fields[0] / 10, at: 56, count: 2)
        let sync: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
        bits.replaceSubrange(64..<80, with: sync)
        return bits
    }
}

/// Deterministic pseudo-random numbers in 0..<1, so tests never flake.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}
