/// One frame of SMPTE Linear Timecode decoded from audio.
public struct LTCFrame: Hashable, Sendable {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    /// The drop-frame flag (bit 10) is set.
    public var isDropFrame: Bool
    /// The frame rate, from the drop-frame flag, the frame numbers seen so far
    /// and the length of each frame in samples.
    public var frameRate: FrameRate
    /// The word arrived back to front: the tape or playhead is running backwards.
    public var isReverse: Bool
    /// Index, counted over every sample ever fed to the decoder, where this
    /// frame's 80-bit word started. Its timecode is the time at that sample.
    public var startSample: Int
    /// Index where the word ended.
    public var endSample: Int

    public var fields: [Int] { [hours, minutes, seconds, frames] }
}

/// Streaming decoder for SMPTE 12M Linear Timecode audio.
///
/// Feed it mono samples in any block size; it returns each frame as its
/// 80-bit word completes. LTC is biphase-mark coded: every bit starts with a
/// level change and a 1 has a second change in the middle. Only the time
/// between changes matters, so the decoder works whatever the signal's
/// polarity, and it tracks the bit length as playback speed drifts.
public struct LTCDecoder: Sendable {
    public let sampleRate: Double

    // Signal conditioning.
    private var dcInput: Float = 0
    private var dcOutput: Float = 0
    private var peak: Float = 0
    private let peakDecay: Float
    private var previousSample: Float = 0
    private var isHigh: Bool?

    // Bit timing, in samples.
    private var sampleIndex = 0
    private var lastTransition: Double?
    private var bitLength: Double
    private var pendingHalfStart: Double?

    // The most recent bits and where each started.
    private var bits: [UInt8] = []
    private var bitStarts: [Double] = []

    // Frame-rate evidence.
    private var previousFrame: (fields: [Int], reverse: Bool)?
    private var rateFromWrap: Int?
    private var highestFrameSeen = 0

    /// Signals quieter than this (about -46 dBFS) are treated as silence.
    private static let noiseFloor: Float = 0.005
    private static let syncForward: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
    private static let syncReverse: [UInt8] = syncForward.reversed()

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // Start between the 24 and 30 fps bit lengths; it adapts from there.
        self.bitLength = sampleRate / (80 * 27)
        // The peak falls by half every 50 ms of silence.
        self.peakDecay = Float(pow2(-1 / (0.05 * sampleRate)))
    }

    /// Decodes a block of samples (-1...1) and returns the frames it completed.
    public mutating func decode(_ samples: [Float]) -> [LTCFrame] {
        var frames: [LTCFrame] = []
        for raw in samples {
            // Remove any DC offset so the level detector centres on zero.
            let sample = raw - dcInput + 0.999 * dcOutput
            dcInput = raw
            dcOutput = sample

            peak = max(abs(sample), peak * peakDecay)
            let threshold = max(peak * 0.3, Self.noiseFloor)

            if sample > threshold, isHigh != true {
                if isHigh != nil { transition(at: crossing(threshold, sample), into: &frames) }
                isHigh = true
            } else if sample < -threshold, isHigh != false {
                if isHigh != nil { transition(at: crossing(-threshold, sample), into: &frames) }
                isHigh = false
            }
            previousSample = sample
            sampleIndex += 1
        }
        return frames
    }

    /// Where between the previous sample and this one the signal crossed `level`.
    private func crossing(_ level: Float, _ sample: Float) -> Double {
        let span = sample - previousSample
        let fraction = span == 0 ? 1 : Double((level - previousSample) / span)
        return Double(sampleIndex - 1) + min(max(fraction, 0), 1)
    }

    private mutating func transition(at time: Double, into frames: inout [LTCFrame]) {
        defer { lastTransition = time }
        guard let last = lastTransition else { return }
        let interval = time - last

        if interval > 2.2 * bitLength {
            // A gap: the signal dropped out. Start over.
            resetBits()
            return
        }
        if interval < 0.75 * bitLength {
            // Half a bit: two in a row make a 1.
            if let start = pendingHalfStart {
                pendingHalfStart = nil
                adaptBitLength(to: time - start)
                push(1, startingAt: start, endingAt: time, into: &frames)
            } else {
                pendingHalfStart = last
            }
        } else {
            // A whole bit with no change in the middle: a 0. A lone half before
            // it means we were out of step; the sync word puts us back.
            pendingHalfStart = nil
            adaptBitLength(to: interval)
            push(0, startingAt: last, endingAt: time, into: &frames)
        }
    }

    private mutating func adaptBitLength(to measured: Double) {
        bitLength += 0.1 * (measured - bitLength)
    }

    private mutating func resetBits() {
        bits.removeAll(keepingCapacity: true)
        bitStarts.removeAll(keepingCapacity: true)
        pendingHalfStart = nil
    }

    private mutating func push(_ bit: UInt8, startingAt start: Double, endingAt end: Double, into frames: inout [LTCFrame]) {
        bits.append(bit)
        bitStarts.append(start)
        if bits.count > 80 {
            bits.removeFirst()
            bitStarts.removeFirst()
        }
        guard bits.count == 80 else { return }

        let word: [UInt8]
        let reverse: Bool
        if Array(bits[64..<80]) == Self.syncForward {
            word = bits
            reverse = false
        } else if Array(bits[0..<16]) == Self.syncReverse {
            word = bits.reversed()
            reverse = true
        } else {
            return
        }

        let wordStart = bitStarts[0]
        resetBits()
        // The whole word's length pins down the bit length exactly.
        bitLength = (end - wordStart) / 80
        if let frame = parse(word, reverse: reverse, start: wordStart, end: end) {
            frames.append(frame)
        }
    }

    private mutating func parse(_ word: [UInt8], reverse: Bool, start: Double, end: Double) -> LTCFrame? {
        func bcd(_ from: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | Int(word[from + $1]) << $1 }
        }
        let frameUnits = bcd(0, 4), secondUnits = bcd(16, 4), minuteUnits = bcd(32, 4), hourUnits = bcd(48, 4)
        guard [frameUnits, secondUnits, minuteUnits, hourUnits].allSatisfy({ $0 <= 9 }) else { return nil }
        let frames = bcd(8, 2) * 10 + frameUnits
        let seconds = bcd(24, 3) * 10 + secondUnits
        let minutes = bcd(40, 3) * 10 + minuteUnits
        let hours = bcd(56, 2) * 10 + hourUnits
        guard frames < 30, seconds < 60, minutes < 60, hours < 24 else { return nil }
        let dropFrame = word[10] == 1

        let fields = [hours, minutes, seconds, frames]
        let rate = detectRate(fields: fields, reverse: reverse, dropFrame: dropFrame, samples: end - start)
        previousFrame = (fields, reverse)
        return LTCFrame(hours: hours, minutes: minutes, seconds: seconds, frames: frames,
                        isDropFrame: dropFrame, frameRate: rate, isReverse: reverse,
                        startSample: Int(start.rounded(.down)), endSample: Int(end.rounded(.down)))
    }

    /// LTC carries no frame rate except the drop-frame flag. The surest sign is
    /// the last frame number before the seconds roll over (23, 24 or 29); until
    /// one has been seen, the frame's length decides, never below a frame
    /// number already seen.
    private mutating func detectRate(fields: [Int], reverse: Bool, dropFrame: Bool, samples: Double) -> FrameRate {
        let frameNumber = fields[3]
        highestFrameSeen = max(highestFrameSeen, frameNumber)
        if let wrap = rateFromWrap, frameNumber >= wrap { rateFromWrap = nil }

        if let previous = previousFrame, previous.reverse == reverse {
            let (before, after) = reverse ? (fields, previous.fields) : (previous.fields, fields)
            if after[3] == 0, [23, 24, 29].contains(before[3]), (before[2] + 1) % 60 == after[2] {
                rateFromWrap = before[3] + 1
            }
        }
        if dropFrame { return .fps2997DropFrame }

        let fps: Int
        if let wrap = rateFromWrap {
            fps = wrap
        } else {
            let measured = sampleRate / samples
            let candidates = [24, 25, 30].filter { $0 > highestFrameSeen }
            fps = candidates.min { abs(Double($0) - measured) < abs(Double($1) - measured) } ?? 30
        }
        switch fps {
        case 24: return .fps24
        case 25: return .fps25
        default: return .fps30
        }
    }
}

/// 2^x without Foundation.
private func pow2(_ x: Double) -> Double {
    // exp(x ln 2) by a short series is plenty for a decay constant near 1.
    let y = x * 0.693_147_180_559_945_3
    var term = 1.0, sum = 1.0
    for n in 1...12 {
        term *= y / Double(n)
        sum += term
    }
    return sum
}
