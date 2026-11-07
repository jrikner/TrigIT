import Foundation
import TrigITEngine

/// Connects the pure Show Engine and the Simulator to the UI. It owns the clock:
/// a timer polls the Simulator and feeds each new reading to the engine.
@MainActor
final class ShowModel: ObservableObject {
    /// A Song that fired, kept for the on-screen list. Nothing is sent to any
    /// device yet; this shows what would fire.
    struct Firing: Identifiable {
        let id = UUID()
        let songName: String
        let timecode: Timecode
    }

    @Published private(set) var set: ShowSet
    @Published private(set) var playhead: Timecode?
    @Published private(set) var frameRate: FrameRate?
    @Published private(set) var currentSongID: SongID?
    @Published private(set) var firings: [Firing] = []
    @Published private(set) var simulator = Simulator(frameRate: .fps25)

    private var engine: ShowEngine
    private var timer: Timer?
    private var lastFedTimecode: Timecode?

    init(set: ShowSet = ShowModel.exampleSet) {
        self.set = set
        self.engine = ShowEngine(set: set)
        startClock()
    }

    var currentSong: Song? {
        set.songs.first { $0.id == currentSongID }
    }

    // MARK: Set editing

    func addSong() {
        let start = nextFreeHour()
        let song = Song(
            name: "Song \(set.songs.count + 1)",
            start: start,
            end: Timecode(hours: start.hours, minutes: 5, seconds: 0, frames: 0)!
        )
        set.songs.append(song)
        engine.updateSet(set)
    }

    func deleteSong(_ id: SongID) {
        set.songs.removeAll { $0.id == id }
        engine.updateSet(set)
    }

    func update(_ song: Song) {
        guard let index = set.songs.firstIndex(where: { $0.id == song.id }) else { return }
        set.songs[index] = song
        engine.updateSet(set)
    }

    // MARK: Simulator

    func play(from position: Timecode? = nil) {
        simulator.play(from: position, at: now)
        lastFedTimecode = nil
        tick()
    }

    func stop() {
        simulator.stop(at: now)
    }

    func jump(to position: Timecode) {
        simulator.jump(to: position, at: now)
        tick()
    }

    func setSimulatorFrameRate(_ rate: FrameRate) {
        simulator.setFrameRate(rate, at: now)
        tick()
    }

    // MARK: Clock

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func startClock() {
        // 100 Hz polling resolves every frame at up to 30 fps.
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let reading = simulator.reading(at: now), reading.timecode != lastFedTimecode else { return }
        lastFedTimecode = reading.timecode
        for event in engine.handle(reading) {
            apply(event)
        }
    }

    private func apply(_ event: EngineEvent) {
        switch event {
        case .playheadMoved(let timecode):
            playhead = timecode
        case .frameRateChanged(let rate):
            frameRate = rate
        case .currentSongChanged(let id):
            currentSongID = id
        case .fired(let id):
            guard let song = set.songs.first(where: { $0.id == id }), let playhead else { return }
            firings.insert(Firing(songName: song.name, timecode: playhead), at: 0)
            if firings.count > 50 { firings.removeLast() }
        case .jumped:
            break
        }
    }

    private func nextFreeHour() -> Timecode {
        let lastHour = set.songs.map(\.end.hours).max() ?? 0
        return Timecode(hours: min(lastHour + 1, 23), minutes: 0, seconds: 0, frames: 0)!
    }

    /// A small Set to try the Simulator with straight away (Sets are not saved yet).
    static let exampleSet = ShowSet(name: "Example Set", songs: [
        Song(name: "Intro", start: Timecode("01:00:00:00")!, end: Timecode("01:04:00:00")!),
        Song(name: "DJ Pull-up", start: Timecode("02:00:00:00")!, end: Timecode("02:01:30:00")!),
    ])
}
