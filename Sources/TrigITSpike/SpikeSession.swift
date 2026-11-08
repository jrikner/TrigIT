// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TrigITEngine
import TrigITProtocols

/// The platform-free half of the Windows spike: it feeds timecode to the Show
/// Engine (always Armed), turns the engine's OSC sends into datagrams for the
/// caller to send, and records the timing the report is made of. All times are
/// seconds on one monotonic clock that the caller reads.
public struct SpikeSession {
    /// One OSC datagram to send now, then report back with `sent(_:at:error:)`.
    public struct Send: Sendable {
        public var bytes: [UInt8]
        public var host: String
        public var port: UInt16
        /// Index into the fire log, for the latency bookkeeping.
        let fire: Int
        let arrivedAt: Double
    }

    /// What one input produced: datagrams to send, and lines worth printing.
    public struct Step {
        public var sends: [Send] = []
        public var notes: [String] = []
    }

    struct Fire {
        var time: Double
        var songName: String
        var timecode: Timecode
        var ended: Bool
        /// Frames after the Song's start time, when it played in naturally.
        var framesLate: Int?
        var sends = 0
        var failures = 0
    }

    struct SourceStats {
        var frames = 0
        var frameRate: FrameRate?
        var lastArrival: Double?
        /// |interval - nominal frame interval| between consecutive frames, in seconds.
        var jitter: [Double] = []
    }

    public private(set) var engine: ShowEngine
    private let startedAt: Double
    private var sources: [TimecodeSourceKind: SourceStats] = [:]
    private var fires: [Fire] = []
    private var latencies: [Double] = []
    private var tickIntervals: [Double] = []
    private var lastTick: Double?
    private var failedSends = 0
    private var skippedActions = 0
    private var ignoredPackets = 0
    private var dropouts: [Double] = []
    private var stops = 0
    private var sourceLosses = 0
    private var doubleFires = 0
    private var missedFires = 0
    /// The Song that fired and has neither been left nor Stopped since.
    private var firedAndStillIn: SongID?
    /// The previous reading's timecode, nil after a Stop or before any reading.
    private var lastTimecode: Timecode?

    public init(set: ShowSet, startedAt: Double) {
        engine = ShowEngine(set: set, armed: true)
        self.startedAt = startedAt
    }

    /// An Art-Net packet arrived. Anything other than ArtTimeCode is ignored.
    public mutating func receiveArtNet(_ packet: [UInt8], arrivedAt: Double, role: SourceRole) -> Step {
        guard let artTimeCode = ArtTimeCode(packet: packet), let timecode = Timecode(artTimeCode.fields) else {
            ignoredPackets += 1
            return Step()
        }
        let reading = TimecodeReading(timecode: timecode, frameRate: artTimeCode.frameRate, source: .artNet, timestamp: arrivedAt)
        return receive(reading, arrivedAt: arrivedAt, role: role)
    }

    /// An LTC frame was decoded. `startedAt` is when its first sample was
    /// recorded; `arrivedAt` is when its audio reached the app.
    public mutating func receiveLTC(_ frame: LTCFrame, startedAt: Double, arrivedAt: Double, role: SourceRole) -> Step {
        guard let timecode = Timecode(hours: frame.hours, minutes: frame.minutes, seconds: frame.seconds, frames: frame.frames)
        else { return Step() }
        let reading = TimecodeReading(timecode: timecode, frameRate: frame.frameRate, source: .ltc, timestamp: startedAt)
        return receive(reading, arrivedAt: arrivedAt, role: role)
    }

    /// The clock ticked: lets the engine notice Stops and lost sources.
    public mutating func tick(at time: Double) -> Step {
        if let lastTick { tickIntervals.append(time - lastTick) }
        lastTick = time
        return apply(engine.tick(at: time), arrivedAt: time, reading: nil)
    }

    /// Reports how a send went: `error` is nil when the datagram went out.
    public mutating func sent(_ send: Send, at time: Double, error: String?) {
        if error == nil {
            latencies.append(time - send.arrivedAt)
            fires[send.fire].sends += 1
        } else {
            failedSends += 1
            fires[send.fire].failures += 1
        }
    }

    private mutating func receive(_ reading: TimecodeReading, arrivedAt: Double, role: SourceRole) -> Step {
        // In place, so the jitter array isn't copied on every frame.
        Self.record(reading, arrivedAt: arrivedAt, in: &sources[reading.source, default: SourceStats()])
        let events = engine.handle(reading, from: role)
        // A reading from the source the engine isn't following changes nothing.
        return apply(events, arrivedAt: arrivedAt, reading: engine.liveSource == role ? reading : nil)
    }

    private static func record(_ reading: TimecodeReading, arrivedAt: Double, in stats: inout SourceStats) {
        stats.frames += 1
        if stats.frameRate == reading.frameRate, let last = stats.lastArrival, arrivedAt - last <= ShowEngine.dropoutThreshold {
            stats.jitter.append(abs(arrivedAt - last - 1 / reading.frameRate.realFramesPerSecond))
        }
        stats.frameRate = reading.frameRate
        stats.lastArrival = arrivedAt
    }

    private mutating func apply(_ events: [EngineEvent], arrivedAt: Double, reading: TimecodeReading?) -> Step {
        var step = Step()
        let jumped = events.contains { if case .jumped = $0 { return true } else { return false } }
        let playedOn = lastTimecode != nil && !jumped
        var enteredWithoutFiring: SongID?
        for event in events {
            switch event {
            case .currentSongChanged(let songID):
                if firedAndStillIn != songID { firedAndStillIn = nil }
                enteredWithoutFiring = songID
            case .fired(let songID, _), .ended(let songID, _):
                guard let song = engine.set.songs.first(where: { $0.id == songID }), let reading else { break }
                let ended: Bool
                if case .ended = event { ended = true } else { ended = false }
                if !ended {
                    if enteredWithoutFiring == songID { enteredWithoutFiring = nil }
                    if firedAndStillIn == songID {
                        doubleFires += 1
                        step.notes.append("DOUBLE FIRE: \(song.name) fired again without leaving it or a Stop")
                    }
                    firedAndStillIn = songID
                }
                let rate = reading.frameRate
                let late = playedOn && !ended ? reading.timecode.frameIndex(at: rate) - song.start.frameIndex(at: rate) : nil
                fires.append(Fire(time: arrivedAt, songName: song.name, timecode: reading.timecode, ended: ended, framesLate: late))
                step.notes.append("\(reading.timecode)  \(ended ? "ended" : "fired") \(song.name)\(late.map { $0 > 0 ? " (\($0) frames late)" : "" } ?? "")")
            case .send(let outgoing):
                guard case .osc(let message) = outgoing.action.message, outgoing.destination.usesOSC, !fires.isEmpty else {
                    skippedActions += 1
                    break
                }
                step.sends.append(Send(bytes: message.encoded(), host: outgoing.destination.host, port: outgoing.destination.port,
                                       fire: fires.count - 1, arrivedAt: arrivedAt))
            case .missingDestination:
                skippedActions += 1
            case .dropout(let seconds):
                dropouts.append(seconds)
                step.notes.append(String(format: "dropout: no timecode for %.2f s", seconds))
            case .stopped:
                stops += 1
                firedAndStillIn = nil
                lastTimecode = nil
                step.notes.append("timecode stopped")
            case .jumped(let from, let to):
                step.notes.append("jump \(from) -> \(to)")
            case .sourceHealthChanged(let role, let healthy):
                if !healthy { sourceLosses += 1 }
                step.notes.append("\(role.rawValue) source \(healthy ? "receiving" : "lost")")
            case .liveSourceChanged(let role):
                step.notes.append("now following the \(role.rawValue) source")
            default:
                break
            }
        }
        if let songID = enteredWithoutFiring, engine.set.songs.contains(where: { $0.id == songID }) {
            missedFires += 1
            step.notes.append("MISSED FIRE: entered a Song without firing it")
        }
        if let reading { lastTimecode = reading.timecode }
        return step
    }

    // MARK: Report

    /// What the report says about where it ran; the platform layer fills it in.
    public struct Environment {
        public var computer: String
        public var setName: String
        public var sources: String
        public var timer: String
        public var tickPeriod: Double

        public init(computer: String, setName: String, sources: String, timer: String, tickPeriod: Double) {
            self.computer = computer
            self.setName = setName
            self.sources = sources
            self.timer = timer
            self.tickPeriod = tickPeriod
        }
    }

    /// The plain-text timing report, for attaching to a GitHub comment.
    public func report(_ environment: Environment, endedAt: Double, generated: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let starts = fires.filter { !$0.ended }
        let lateFires = starts.filter { ($0.framesLate ?? 0) > 0 }.count
        let songCount = engine.set.songs.count

        var lines = [
            "TrigIT Windows spike: timing report",
            "Generated: \(formatter.string(from: generated))",
            "Computer: \(environment.computer)",
            "Set: \(environment.setName) (\(songCount) Song\(songCount == 1 ? "" : "s"))",
            "Sources: \(environment.sources)",
            "Timer: \(environment.timer)",
            "Ran for: \(Self.duration(endedAt - startedAt))",
            "",
            "Summary",
            "  Songs fired: \(starts.count) (late: \(lateFires), double: \(doubleFires), missed: \(missedFires))",
            "  Songs ended: \(fires.count - starts.count)",
            "  OSC sends: \(latencies.count) sent, \(failedSends) failed, \(skippedActions) skipped (MIDI/DMX/missing Destination)",
            "  Dropouts: \(dropouts.count)\(dropouts.max().map { String(format: " (longest %.2f s)", $0) } ?? ""), Stops: \(stops), source lost: \(sourceLosses)",
            "  Art-Net packets that were not timecode: \(ignoredPackets)",
            "",
        ]
        for kind in TimecodeSourceKind.allCases {
            guard let stats = sources[kind], let rate = stats.frameRate else { continue }
            let name = kind == .ltc ? "LTC" : "Art-Net Timecode"
            let interval = String(format: "%.1f", 1000 / rate.realFramesPerSecond)
            lines.append("Frame arrival, \(name) at \(rate.rawValue) fps (one frame every \(interval) ms): \(stats.frames) frames")
            lines.append("  jitter (ms off the frame interval): " + Self.percentiles(stats.jitter))
        }
        lines.append("Send latency (timecode arrived -> OSC sent), \(latencies.count) sends")
        lines.append("  ms: " + Self.percentiles(latencies))
        lines.append(String(format: "Clock ticks (target every %.0f ms), %d ticks", environment.tickPeriod * 1000, tickIntervals.count + (lastTick == nil ? 0 : 1)))
        lines.append("  interval ms: " + Self.percentiles(tickIntervals))
        lines.append("")
        lines.append("Fires")
        if fires.isEmpty { lines.append("  (none)") }
        let shown = 500
        for fire in fires.prefix(shown) {
            let late = fire.framesLate.map { $0 > 0 ? ", \($0) frames late" : ", on time" } ?? ""
            let failed = fire.failures > 0 ? ", \(fire.failures) FAILED" : ""
            let at = String(format: "%8.3f s", fire.time - startedAt)
            lines.append("  \(at)  \(fire.timecode)  \(fire.ended ? "ended" : "fired") \(fire.songName): \(fire.sends) sent\(failed)\(late)")
        }
        if fires.count > shown { lines.append("  ... and \(fires.count - shown) more") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "p50 0.12, p95 0.40, p99 0.95, max 1.20" in milliseconds.
    static func percentiles(_ seconds: [Double]) -> String {
        guard !seconds.isEmpty else { return "no data" }
        let sorted = seconds.sorted()
        func ms(_ value: Double) -> String { String(format: "%.2f", value * 1000) }
        let parts = [50, 95, 99].map { "p\($0) \(ms(percentile($0, ofSorted: sorted)))" }
        return (parts + ["max \(ms(sorted.last!))"]).joined(separator: ", ")
    }

    /// Nearest-rank percentile of an ascending, non-empty list.
    static func percentile(_ p: Int, ofSorted sorted: [Double]) -> Double {
        let rank = Int((Double(p) / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total) s" : "\(total / 60) min \(total % 60) s"
    }
}
