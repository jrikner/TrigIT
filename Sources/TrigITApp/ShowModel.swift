import Foundation
import SwiftUI // for MutableCollection.move(fromOffsets:toOffset:)
import TrigITEngine
import TrigITProtocols
import TrigITStorage

/// The Timecode Source the show follows.
enum TimecodeSourceChoice: Hashable {
    case simulator
    /// LTC on one channel (0-based) of an audio input, remembered by device UID.
    case ltc(deviceUID: String, channel: Int)
    /// MTC from a MIDI source, remembered by its Core MIDI unique ID.
    case mtc(sourceID: Int32)
    /// Art-Net Timecode on a network interface (BSD name), or on any interface if nil.
    case artNet(interface: String?)
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

    @Published private(set) var set: ShowSet {
        // Keep streaming exactly the DMX universes the Set uses.
        didSet { dmxStreamer.update(for: set) }
    }
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
    @Published private(set) var midiOutputs: [MIDIOutputInfo] = []
    /// Whether timecode is arriving from the chosen source right now.
    @Published private(set) var isReceiving = false
    /// While locked the Set is read-only; arming and the Simulator still work.
    @Published private(set) var isShowLocked = false
    /// The last Song edit refused because it would overlap other Songs.
    @Published private(set) var refusedEdit: RefusedEdit?

    // Set file (see SetDocument.swift).
    /// Where the Set is saved; nil when it couldn't be opened and isn't saved anywhere yet.
    @Published var documentURL: URL?
    /// Why the Set couldn't be opened or saved, shown until resolved.
    @Published var documentProblem: String?
    @Published var recentDocuments: [URL] = []
    @Published var showingVersions = false
    @Published var canUndo = false
    @Published var canRedo = false
    var history = EditHistory<ShowSet>()
    /// The model of the running app, for the app delegate.
    static weak var current: ShowModel?
    var pendingSave: DispatchWorkItem?
    var lastVersionSaved: Date?
    let versionStore = SetVersionStore(directory: ShowModel.applicationSupport.appendingPathComponent("Versions", isDirectory: true))

    struct RefusedEdit: Equatable {
        let songID: SongID
        let conflicts: [SongID]
        let message: String
    }

    private var engine: ShowEngine
    private let sender = UDPSender()
    private let audioDevices = AudioDeviceList()
    private let ltcInput = LTCAudioInput()
    private let midiInput = MIDIInput()
    private let midiOutput = MIDIOutput()
    private let dmxStreamer = DMXStreamer()
    private var midiParser = MIDIParser()
    private var mtcDecoder = MTCDecoder()
    private let artNetInput = ArtNetTimecodeInput()
    private var timer: Timer?
    private var lastFedTimecode: Timecode?
    private var lastReadingTime: Double?

    /// No reading for this long means the signal is gone (LTC sends one per frame).
    private static let signalTimeout = 0.25

    private static let maxLogEntries = 500

    init() {
        let set = ShowSet()
        self.set = set
        self.engine = ShowEngine(set: set, armed: false)
        sender.onInterfacesChanged = { [weak self] interfaces in self?.networkInterfacesChanged(interfaces) }
        audioDevices.onChange = { [weak self] in self?.audioDevicesChanged() }
        ltcInput.onFrame = { [weak self] frame, time in self?.receive(frame, at: time) }
        audioInputDevices = audioDevices.inputDevices()
        midiInput.onSourcesChanged = { [weak self] in self?.midiSourcesChanged() }
        midiInput.onBytes = { [weak self] bytes, time in self?.receiveMIDI(bytes, at: time) }
        midiSources = midiInput.sources()
        midiOutput.onOutputsChanged = { [weak self] in
            guard let self else { return }
            self.midiOutputs = self.midiOutput.outputs()
        }
        midiOutputs = midiOutput.outputs()
        dmxStreamer.onError = { [weak self] message in self?.record(message, isError: true) }
        dmxStreamer.update(for: set)
        artNetInput.onPacket = { [weak self] packet, time in self?.receiveArtNet(packet, at: time) }
        if let status = midiInput.startError { record("MIDI is unavailable (error \(status))", isError: true) }
        openLastDocument()
        startClock()
    }

    var currentSong: Song? {
        self.set.songs.first { $0.id == currentSongID }
    }

    // MARK: Armed

    func setArmed(_ armed: Bool) {
        apply(engine.setArmed(armed))
        if !armed { midiOutput.releaseAllNotes() }
    }

    // MARK: Show Lock

    func setShowLocked(_ locked: Bool) {
        guard locked != isShowLocked else { return }
        isShowLocked = locked
        record(locked ? "Show Lock on: the Set is read-only" : "Show Lock off")
    }

    /// Runs an edit to the Set unless Show Lock is on; records it for undo
    /// and saves it.
    private func edit(_ change: (inout ShowSet) -> Void) {
        guard !isShowLocked else { return }
        let before = set
        change(&set)
        guard set != before else { return }
        history.record(before: before, at: now)
        setDidChange()
    }

    /// After any change to the Set: the engine follows it and it is saved.
    func setDidChange() {
        engine.updateSet(set)
        canUndo = history.canUndo
        canRedo = history.canRedo
        scheduleSave()
    }

    /// Replaces the whole Set (opening, restoring, undo) without recording an edit.
    func replaceSet(_ newSet: ShowSet) {
        set = newSet
        refusedEdit = nil
        engine.updateSet(newSet)
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    func record(_ text: String, isError: Bool = false) {
        record(text, timecode: nil, isError: isError)
    }

    // MARK: Songs

    func addSong() {
        let start = nextFreeHour()
        let song = Song(
            name: "Song \(set.songs.count + 1)",
            start: start,
            end: Timecode(hours: start.hours, minutes: 5, seconds: 0, frames: 0)!
        )
        update(song)
    }

    func deleteSong(_ id: SongID) {
        edit { $0.songs.removeAll { $0.id == id } }
        if refusedEdit?.songID == id { refusedEdit = nil }
    }

    /// Applies an edit to a Song (or adds it). Returns false, and records why
    /// in `refusedEdit`, if it would overlap another Song or Show Lock is on.
    @discardableResult
    func update(_ song: Song) -> Bool {
        guard !isShowLocked else { return false }
        var conflicts: [Song] = []
        edit { conflicts = $0.apply(song) }
        if conflicts.isEmpty {
            if refusedEdit?.songID == song.id { refusedEdit = nil }
            return true
        }
        let names = conflicts.map { "\"\($0.name)\"" }.joined(separator: ", ")
        refusedEdit = RefusedEdit(songID: song.id, conflicts: conflicts.map(\.id),
                                  message: "\(song.name) would overlap \(names); not changed")
        return false
    }

    func song(_ id: SongID) -> Song? {
        set.songs.first { $0.id == id }
    }

    /// Sets a Song's start to the live Playhead.
    func captureStart(for songID: SongID) {
        guard let playhead, var song = song(songID) else { return }
        song.start = playhead
        update(song)
    }

    /// Sets a Song's end to the live Playhead.
    func captureEnd(for songID: SongID) {
        guard let playhead, var song = song(songID) else { return }
        song.end = playhead
        update(song)
    }

    /// Adds Songs from CSV text and reports what happened in the log.
    func importSongs(csv text: String, fileName: String) -> SongImportReport? {
        guard !isShowLocked else { return nil }
        var report = SongImportReport()
        edit { report = $0.importSongs(csv: text) }
        record("Imported \(report.imported.count) Song(s) from \(fileName); skipped \(report.problems.count) row(s)",
               isError: !report.problems.isEmpty)
        return report
    }

    // MARK: Actions

    /// A Song's two Action lists.
    enum ActionList: Hashable {
        case start, stop

        var keyPath: WritableKeyPath<Song, [Action]> {
            self == .start ? \.startActions : \.stopActions
        }
    }

    /// The kinds of Action the editor can add.
    enum NewActionKind: CaseIterable {
        case osc, midiNote, msc, dmxPulse

        var label: String {
            switch self {
            case .osc: return "OSC message"
            case .midiNote: return "MIDI note"
            case .msc: return "MIDI Show Control"
            case .dmxPulse: return "Art-Net / sACN pulse"
            }
        }

        var message: Action.Message {
            switch self {
            case .osc: return .osc(OSCMessage(address: "/"))
            case .midiNote: return .midiNote(MIDINote(channel: 0, note: 60))
            case .msc: return .msc(MSCCommand(command: .go, cue: "1"))
            case .dmxPulse: return .dmxPulse(DMXPulse(universe: 1, channel: 1))
            }
        }

        /// Whether a Destination has what this kind of Action needs.
        func canUse(_ destination: Destination) -> Bool {
            switch self {
            case .osc: return true
            case .midiNote, .msc: return destination.midiOutput != nil
            case .dmxPulse: return destination.dmxOutput != nil
            }
        }
    }

    func addAction(_ kind: NewActionKind, to songID: SongID, list: ActionList) {
        guard var song = song(songID) else { return }
        // Prefer a Destination that can carry it: a MIDI output for MIDI, DMX for pulses.
        let destination = set.destinations.first { kind.canUse($0) } ?? set.destinations.first
        guard let destination else { return }
        song[keyPath: list.keyPath].append(Action(destinationID: destination.id, message: kind.message))
        update(song)
    }

    /// Replaces the Action with the same ID, in whichever list holds it.
    func update(_ action: Action, in songID: SongID) {
        guard var song = song(songID) else { return }
        for list in [ActionList.start, .stop] {
            if let index = song[keyPath: list.keyPath].firstIndex(where: { $0.id == action.id }) {
                song[keyPath: list.keyPath][index] = action
            }
        }
        update(song)
    }

    func deleteAction(_ actionID: ActionID, in songID: SongID) {
        guard var song = song(songID) else { return }
        song.startActions.removeAll { $0.id == actionID }
        song.stopActions.removeAll { $0.id == actionID }
        update(song)
    }

    func moveActions(in songID: SongID, list: ActionList, from offsets: IndexSet, to destination: Int) {
        guard var song = song(songID) else { return }
        song[keyPath: list.keyPath].move(fromOffsets: offsets, toOffset: destination)
        update(song)
    }

    // MARK: Manual firing (allowed under Show Lock and while disarmed)

    func fire(_ songID: SongID) {
        apply(engine.fire(songID))
    }

    func fireStop(_ songID: SongID) {
        apply(engine.fireStop(songID))
    }

    // MARK: Stop time

    func setStopTime(_ seconds: Double) {
        edit { $0.stopTime = seconds }
    }

    // MARK: Destinations

    func addDestination() {
        edit { set in
            set.destinations.append(Destination(
                name: "Destination \(set.destinations.count + 1)", host: "127.0.0.1", port: 7000
            ))
        }
    }

    func update(_ destination: Destination) {
        edit { set in
            guard let index = set.destinations.firstIndex(where: { $0.id == destination.id }) else { return }
            set.destinations[index] = destination
        }
    }

    /// Destinations used by any Action can't be deleted.
    func deleteDestination(_ id: DestinationID) {
        edit { set in
            guard !set.isInUse(id) else { return }
            set.destinations.removeAll { $0.id == id }
        }
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
        artNetInput.stop()
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
        case .artNet:
            record("Timecode Source: \(sourceLabel(choice))")
            startArtNet()
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
        case .artNet(let interface):
            guard let interface else { return "Art-Net Timecode: any network interface" }
            let label = networkInterfaces.first { $0.name == interface }?.label ?? "\(interface) (not available)"
            return "Art-Net Timecode: \(label)"
        }
    }

    private func startArtNet() {
        guard case .artNet(let interface) = source else { return }
        do {
            try artNetInput.start(interface: interface)
        } catch {
            record("Art-Net Timecode input failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func receiveArtNet(_ packet: [UInt8], at time: Double) {
        guard case .artNet = source, let artTimeCode = ArtTimeCode(packet: packet),
              let timecode = Timecode(artTimeCode.fields) else { return }
        feed(TimecodeReading(timecode: timecode, frameRate: artTimeCode.frameRate, source: .artNet, timestamp: time))
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

    private func networkInterfacesChanged(_ interfaces: [NetworkInterfaceInfo]) {
        let names = Set(networkInterfaces.map(\.name))
        networkInterfaces = interfaces
        // An interface came or went: rebind so a replugged cable is picked up again.
        if case .artNet = source, names != Set(interfaces.map(\.name)) { startArtNet() }
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

    var now: Double { ProcessInfo.processInfo.systemUptime }

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
        apply(engine.tick(at: now))
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
        case .fired(let id, let cause):
            let name = song(id)?.name ?? "?"
            switch cause {
            case .manual: record("Fired \(name) by hand")
            case .entering: record(isArmed ? "Fired \(name)" : "Fired \(name) (disarmed, nothing sent)")
            }
        case .ended(let id, let cause):
            let name = song(id)?.name ?? "?"
            let how: String
            switch cause {
            case .stop: how = "timecode stopped"
            case .playedPastEnd: how = "played past its end"
            case .manual: how = "Fire stop by hand"
            }
            let sends = cause != .manual && !isArmed && !(song(id)?.stopActions.isEmpty ?? true) ? ", disarmed, nothing sent" : ""
            record("\(name) ended (\(how)\(sends))")
        case .stopped:
            record("Timecode stopped")
        case .dropout(let seconds):
            record("Timecode dropout: \(Int((seconds * 1000).rounded())) ms gap", isError: true)
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
        let kind: String
        switch outgoing.reason {
        case .entering, .manualFire: kind = ""
        case .ending, .manualStop: kind = " (Stop Action)"
        }
        let summary = "\(songName)\(kind) → \(destination.name): \(Self.describe(outgoing.action.message))"
        let timecode = playhead

        switch outgoing.action.message {
        case .osc(let message):
            guard message.hasValidAddress else {
                record("\(summary) not sent: invalid OSC address", isError: true)
                return
            }
            sender.send(message.encoded(), to: destination) { [weak self] error in
                if let error {
                    self?.record("\(summary) failed: \(error.localizedDescription)", timecode: timecode, isError: true)
                } else {
                    self?.record(summary, timecode: timecode)
                }
            }
        case .midiNote(let note):
            sendMIDI(summary, to: destination) { try midiOutput.play(note, on: $0) }
        case .msc(let command):
            guard command.isValid else {
                record("\(summary) not sent: cue and list must be numbers like 5 or 12.5, and a list needs a cue", isError: true)
                return
            }
            sendMIDI(summary, to: destination) { try midiOutput.send(command.encoded, to: $0) }
        case .dmxPulse(let pulse):
            do {
                try dmxStreamer.play(pulse, to: destination)
                record(summary)
            } catch {
                record("\(summary) not sent: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func sendMIDI(_ summary: String, to destination: Destination, _ send: (MIDIPortReference) throws -> Void) {
        guard let output = destination.midiOutput else {
            record("\(summary) not sent: \(destination.name) has no MIDI output (Destinations tab)", isError: true)
            return
        }
        do {
            try send(output)
            record(summary)
        } catch {
            record("\(summary) failed: \(error.localizedDescription)", isError: true)
        }
    }

    /// How an Action's message reads in the log and the editor.
    static func describe(_ message: Action.Message) -> String {
        switch message {
        case .osc(let osc):
            return osc.description
        case .midiNote(let note):
            return "Note \(note.noteName) (\(note.note)) ch \(note.channel + 1) vel \(note.velocity)"
        case .msc(let command):
            return command.summary
        case .dmxPulse(let pulse):
            return pulse.summary
        }
    }

    private func record(_ text: String, timecode: Timecode??, isError: Bool = false) {
        log.insert(LogEntry(timecode: timecode ?? playhead, text: text, isError: isError), at: 0)
        if log.count > Self.maxLogEntries { log.removeLast() }
    }

    private func nextFreeHour() -> Timecode {
        let lastHour = set.songs.map(\.end.hours).max() ?? 0
        return Timecode(hours: min(lastHour + 1, 23), minutes: 0, seconds: 0, frames: 0)!
    }

    /// The Set created on first launch, to try things with straight away.
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
