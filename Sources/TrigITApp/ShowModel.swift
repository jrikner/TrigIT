import Foundation
import SwiftUI // for MutableCollection.move(fromOffsets:toOffset:)
import TrigITEngine
import TrigITProtocols

/// The Timecode Source the show follows.
enum TimecodeSourceChoice: Hashable {
    case simulator
    /// LTC on one channel (0-based) of an audio input, remembered by device UID.
    case ltc(deviceUID: String, channel: Int)
    /// MTC from a MIDI source, remembered by its Core MIDI unique ID.
    case mtc(sourceID: Int32)
}

/// Connects the pure Show Engine, the Timecode Sources and the network sender
/// to the UI. It owns the clock: a timer polls the Simulator and watches for
/// lost signal, each reading goes to the engine, and every send the engine
/// asks for goes out here.
@MainActor
final class ShowModel: ObservableObject {
    /// One line in the fire log.
    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let timecode: Timecode?
        let text: String
        let isError: Bool
    }

    @Published private(set) var set: ShowSet
    @Published private(set) var playhead: Timecode?
    @Published private(set) var frameRate: FrameRate?
    @Published private(set) var currentSongID: SongID?
    @Published private(set) var isArmed = false
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var simulator = Simulator(frameRate: .fps25)
    @Published private(set) var networkInterfaces: [NetworkInterfaceInfo] = []
    @Published private(set) var source: TimecodeSourceChoice = .simulator
    @Published private(set) var audioInputDevices: [AudioInputDevice] = []
    @Published private(set) var midiSources: [MIDISourceInfo] = []
    /// Whether timecode is arriving from the chosen source right now.
    @Published private(set) var isReceiving = false

    private var engine: ShowEngine
    private let sender = UDPSender()
    private let audioDevices = AudioDeviceList()
    private let ltcInput = LTCAudioInput()
    private let midiInput = MIDIInput()
    private var midiParser = MIDIParser()
    private var mtcDecoder = MTCDecoder()
    private var timer: Timer?
    private var lastFedTimecode: Timecode?
    private var lastReadingTime: Double?

    /// No reading for this long means the signal is gone (LTC sends one per frame).
    private static let signalTimeout = 0.25

    private static let maxLogEntries = 500

    init(set: ShowSet = ShowModel.exampleSet) {
        self.set = set
        self.engine = ShowEngine(set: set, armed: false)
        sender.onInterfacesChanged = { [weak self] interfaces in self?.networkInterfaces = interfaces }
        audioDevices.onChange = { [weak self] in self?.audioDevicesChanged() }
        ltcInput.onFrame = { [weak self] frame, time in self?.receive(frame, at: time) }
        audioInputDevices = audioDevices.inputDevices()
        midiInput.onSourcesChanged = { [weak self] in self?.midiSourcesChanged() }
        midiInput.onBytes = { [weak self] bytes, time in self?.receiveMIDI(bytes, at: time) }
        midiSources = midiInput.sources()
        if let status = midiInput.startError { record("MIDI is unavailable (error \(status))", isError: true) }
        startClock()
    }

    var currentSong: Song? {
        set.songs.first { $0.id == currentSongID }
    }

    // MARK: Armed

    func setArmed(_ armed: Bool) {
        apply(engine.setArmed(armed))
    }

    // MARK: Songs

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

    func song(_ id: SongID) -> Song? {
        set.songs.first { $0.id == id }
    }

    // MARK: Start Actions

    func addOSCAction(to songID: SongID) {
        guard var song = song(songID), let destination = set.destinations.first else { return }
        song.startActions.append(Action(destinationID: destination.id, message: .osc(OSCMessage(address: "/"))))
        update(song)
    }

    func update(_ action: Action, in songID: SongID) {
        guard var song = song(songID), let index = song.startActions.firstIndex(where: { $0.id == action.id }) else { return }
        song.startActions[index] = action
        update(song)
    }

    func deleteAction(_ actionID: ActionID, in songID: SongID) {
        guard var song = song(songID) else { return }
        song.startActions.removeAll { $0.id == actionID }
        update(song)
    }

    func moveActions(in songID: SongID, from offsets: IndexSet, to destination: Int) {
        guard var song = song(songID) else { return }
        song.startActions.move(fromOffsets: offsets, toOffset: destination)
        update(song)
    }

    // MARK: Destinations

    func addDestination() {
        set.destinations.append(Destination(
            name: "Destination \(set.destinations.count + 1)", host: "127.0.0.1", port: 7000
        ))
        engine.updateSet(set)
    }

    func update(_ destination: Destination) {
        guard let index = set.destinations.firstIndex(where: { $0.id == destination.id }) else { return }
        set.destinations[index] = destination
        engine.updateSet(set)
    }

    /// Destinations used by any Action can't be deleted.
    func deleteDestination(_ id: DestinationID) {
        guard !set.isInUse(id) else { return }
        set.destinations.removeAll { $0.id == id }
        engine.updateSet(set)
    }

    func destinationName(_ id: DestinationID) -> String {
        set.destination(id)?.name ?? "missing Destination"
    }

    // MARK: Timecode Source

    func selectSource(_ choice: TimecodeSourceChoice) {
        guard choice != source else { return }
        source = choice
        ltcInput.stop()
        midiInput.disconnect()
        isReceiving = false
        lastReadingTime = nil
        lastFedTimecode = nil
        switch choice {
        case .simulator:
            record("Timecode Source: Simulator")
        case .ltc:
            record("Timecode Source: \(sourceLabel(choice))")
            startLTC()
        case .mtc:
            record("Timecode Source: \(sourceLabel(choice))")
            startMTC()
        }
    }

    func sourceLabel(_ choice: TimecodeSourceChoice) -> String {
        switch choice {
        case .simulator:
            return "Simulator"
        case .ltc(let uid, let channel):
            let name = audioInputDevices.first { $0.uid == uid }?.name ?? "missing device"
            return "LTC: \(name), channel \(channel + 1)"
        case .mtc(let id):
            return "MTC: \(midiSources.first { $0.uniqueID == id }?.name ?? "missing MIDI source")"
        }
    }

    private func startMTC() {
        guard case .mtc(let id) = source else { return }
        midiParser = MIDIParser()
        mtcDecoder = MTCDecoder()
        if !midiInput.connect(to: id) {
            record("MTC source is not connected; waiting for it", isError: true)
        }
    }

    private func midiSourcesChanged() {
        midiSources = midiInput.sources()
        // The chosen source may have come back or gone; reconnect either way.
        if case .mtc = source { startMTC() }
    }

    private func receiveMIDI(_ bytes: [UInt8], at time: Double) {
        guard case .mtc = source else { return }
        for message in midiParser.parse(bytes) {
            guard let mtc = mtcDecoder.receive(message), let timecode = Timecode(mtc.fields) else { continue }
            feed(TimecodeReading(timecode: timecode, frameRate: mtc.frameRate, source: .mtc, timestamp: time))
        }
    }

    private func startLTC() {
        guard case .ltc(let uid, let channel) = source else { return }
        guard let device = audioInputDevices.first(where: { $0.uid == uid }) else {
            record("LTC device is not connected; waiting for it", isError: true)
            return
        }
        ltcInput.start(device: device.id, channel: channel) { [weak self] error in
            if let error {
                self?.record("LTC input failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func audioDevicesChanged() {
        audioInputDevices = audioDevices.inputDevices()
        // The chosen device may have come back or gone; reopen it either way.
        if case .ltc = source {
            ltcInput.stop()
            startLTC()
        }
    }

    private func receive(_ frame: LTCFrame, at time: Double) {
        guard case .ltc = source,
              let timecode = Timecode(hours: frame.hours, minutes: frame.minutes, seconds: frame.seconds, frames: frame.frames)
        else { return }
        feed(TimecodeReading(timecode: timecode, frameRate: frame.frameRate, source: .ltc, timestamp: time))
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
        if source == .simulator, let reading = simulator.reading(at: now), reading.timecode != lastFedTimecode {
            feed(reading)
        }
        let receiving = lastReadingTime.map { now - $0 < Self.signalTimeout } ?? false
        if receiving != isReceiving { isReceiving = receiving }
    }

    private func feed(_ reading: TimecodeReading) {
        lastFedTimecode = reading.timecode
        lastReadingTime = now
        apply(engine.handle(reading))
    }

    // MARK: Engine events

    private func apply(_ events: [EngineEvent]) {
        for event in events {
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
            let name = song(id)?.name ?? "?"
            record(isArmed ? "Fired \(name)" : "Fired \(name) (disarmed, nothing sent)")
        case .send(let outgoing):
            send(outgoing)
        case .missingDestination(let songID, _):
            record("\(song(songID)?.name ?? "?"): Action skipped, its Destination was deleted", isError: true)
        case .armedChanged(let armed):
            isArmed = armed
            record(armed ? "Armed" : "Disarmed")
        case .jumped:
            break
        }
    }

    private func send(_ outgoing: OutgoingAction) {
        let songName = song(outgoing.songID)?.name ?? "?"
        let destination = outgoing.destination
        switch outgoing.action.message {
        case .osc(let message):
            let summary = "\(songName) → \(destination.name): \(message)"
            guard message.hasValidAddress else {
                record("\(summary) not sent: invalid OSC address", isError: true)
                return
            }
            let timecode = playhead
            sender.send(message.encoded(), to: destination) { [weak self] error in
                if let error {
                    self?.record("\(summary) failed: \(error.localizedDescription)", timecode: timecode, isError: true)
                } else {
                    self?.record(summary, timecode: timecode)
                }
            }
        }
    }

    private func record(_ text: String, timecode: Timecode?? = nil, isError: Bool = false) {
        log.insert(LogEntry(timecode: timecode ?? playhead, text: text, isError: isError), at: 0)
        if log.count > Self.maxLogEntries { log.removeLast() }
    }

    private func nextFreeHour() -> Timecode {
        let lastHour = set.songs.map(\.end.hours).max() ?? 0
        return Timecode(hours: min(lastHour + 1, 23), minutes: 0, seconds: 0, frames: 0)!
    }

    /// A small Set to try things with straight away (Sets are not saved yet).
    static let exampleSet: ShowSet = {
        let resolume = Destination(name: "Resolume", host: "127.0.0.1", port: 7000)
        return ShowSet(
            name: "Example Set",
            songs: [
                Song(name: "Intro", start: Timecode("01:00:00:00")!, end: Timecode("01:04:00:00")!, startActions: [
                    Action(destinationID: resolume.id, message: .osc(OSCMessage(
                        address: "/composition/columns/1/connect", arguments: [.int(1)]
                    ))),
                ]),
                Song(name: "DJ Pull-up", start: Timecode("02:00:00:00")!, end: Timecode("02:01:30:00")!),
            ],
            destinations: [resolume]
        )
    }()
}
