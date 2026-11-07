/// A virtual Timecode Source for programming and testing a Set without real
/// timecode. Pure: callers pass in the current monotonic time.
public struct Simulator: Sendable {
    public private(set) var frameRate: FrameRate
    public private(set) var isPlaying = false

    /// The position at `anchorTime`; while playing, time advances from there.
    private var anchorFrame: Int
    private var anchorTime: Double = 0

    public init(frameRate: FrameRate = .fps25, position: Timecode = .zero) {
        self.frameRate = frameRate
        self.anchorFrame = position.frameIndex(at: frameRate)
    }

    /// The Simulator's position at `time`.
    public func position(at time: Double) -> Timecode {
        Timecode(frameIndex: frameIndex(at: time), rate: frameRate)
    }

    /// The reading the Simulator sends at `time`, or nil while stopped: a
    /// stopped transport sends no timecode, as with real sources.
    public func reading(at time: Double) -> TimecodeReading? {
        guard isPlaying else { return nil }
        return TimecodeReading(timecode: position(at: time), frameRate: frameRate, source: .simulator, timestamp: time)
    }

    /// Starts playing from `position`, or from where it is if nil.
    public mutating func play(from position: Timecode? = nil, at time: Double) {
        anchor(position.map { $0.frameIndex(at: frameRate) } ?? frameIndex(at: time), at: time)
        isPlaying = true
    }

    /// Stops; the position holds where it stopped.
    public mutating func stop(at time: Double) {
        anchor(frameIndex(at: time), at: time)
        isPlaying = false
    }

    /// Moves to `position`, keeping the play state.
    public mutating func jump(to position: Timecode, at time: Double) {
        anchor(position.frameIndex(at: frameRate), at: time)
    }

    /// Changes the frame rate, keeping the displayed position.
    public mutating func setFrameRate(_ rate: FrameRate, at time: Double) {
        let current = position(at: time)
        frameRate = rate
        anchor(current.frameIndex(at: rate), at: time)
    }

    private mutating func anchor(_ frame: Int, at time: Double) {
        anchorFrame = frame
        anchorTime = time
    }

    private func frameIndex(at time: Double) -> Int {
        guard isPlaying else { return anchorFrame }
        let elapsedFrames = Int(((time - anchorTime) * frameRate.realFramesPerSecond).rounded(.down))
        return anchorFrame + max(0, elapsedFrames)
    }
}
