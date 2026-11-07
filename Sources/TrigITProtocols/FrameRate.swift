/// The frame rates a Timecode Source can run at.
public enum FrameRate: String, CaseIterable, Sendable, Codable {
    case fps24 = "24"
    case fps25 = "25"
    case fps2997DropFrame = "29.97 DF"
    case fps30 = "30"

    /// Frames counted per timecode second (the `ff` field runs 0..<nominal).
    public var nominalFramesPerSecond: Int {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps2997DropFrame, .fps30: return 30
        }
    }

    /// Frames per second of real (wall-clock) time.
    public var realFramesPerSecond: Double {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps2997DropFrame: return 30_000.0 / 1_001.0
        case .fps30: return 30
        }
    }

    public var isDropFrame: Bool { self == .fps2997DropFrame }
}
