import AppKit
import Foundation
import SwiftUI // for MutableCollection.move(fromOffsets:toOffset:)
import TrigITEngine
import TrigITProtocols
import TrigITStorage
import UniformTypeIdentifiers

/// The Timecode Source the show follows.
enum TimecodeSourceChoice: Hashable, Codable {
    case simulator
    /// LTC on one channel (0-based) of an audio input, remembered by device UID.
    case ltc(deviceUID: String, channel: Int)
    /// MTC from a MIDI source, remembered by its Core MIDI unique ID.
    case mtc(sourceID: Int32)
    /// Art-Net Timecode on a network interface (BSD name), or on any interface if nil.
    case artNet(interface: String?)

    var kind: TimecodeSourceKind {
        switch self {
        case .simulator: return .simulator
        case .ltc: return .ltc
        case .mtc: return .mtc
        case .artNet: return .artNet
        }
    }
}

/// Connects the pure Show Engine, the Timecode Sources and the network sender
/// to the UI. It owns the clock: a timer polls the Simulator and watches for
/// lost signal, each reading goes to the engine, and every send the engine
/// asks for goes out here.
@MainActor
final class ShowModel: ObservableObject {
    /// One line in the fire log.
    struct LogEntry: Identifiable {
        enum Kind: String, CaseIterable {
            case fired = "Fired", sent = "Sent", failed = "Failed", dropout = "Dropout", stop = "Stop"
            case failover = "Failover", armed = "Armed", disarmed = "Disarmed", info = "Info", problem = "Problem"
        }
        let id = UUID()
        let date = Date()
        let timecode: Timecode?
        let text: String
        let kind: Kind
        var isError: Bool { kind == .failed || kind == .problem || kind == .dropout }
    }

    /// How the last send of an Action went. Kept for this session only, not in the Set file.
    struct SendResult: Equatable {
        let date: Date
        let timecode: Timecode?
        let ok: Bool
        let errorText: String?
    }

    /// The last time a Song fired, for the Show screen's status bar.
    struct Firing: Equatable {
        let songID: SongID
        let date: Date
        let actionIDs: [ActionID]
        let sent: Bool
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
    /// The Primary Source.
    @Published private(set) var source: TimecodeSourceChoice = .simulator
    /// The optional Backup Source, always of a different kind than the Primary.
    @Published private(set) var backupSource: TimecodeSourceChoice?
    /// The source the engine follows right now.
    @Published private(set) var liveSource: SourceRole = .primary
    /// Which sources are sending timecode right now.
    @Published private(set) var healthySources: Set<SourceRole> = []
    /// The timecode problem the banner shows, if any.
    @Published private(set) var alert: TimecodeAlert?
    @Published private(set) var audioInputDevices: [AudioInputDevice] = []
    @Published private(set) var midiSources: [MIDISourceInfo] = []
    /// The MIDI source Start and Stop Notes are heard on, if any. It may be the MTC source.
    @Published private(set) var noteSourceID: Int32?
    @Published private(set) var midiOutputs: [MIDIOutputInfo] = []
    /// Each Destination's status; missing means unknown.
    @Published private(set) var destinationStatuses: [DestinationID: DestinationStatus] = [:]
    /// Whether timecode is arriving from the live source right now.
    var isReceiving: Bool { healthySources.contains(liveSource) }
    /// While locked the Set is read-only; arming and the Simulator still work.
    @Published private(set) var isShowLocked = false
    /// The last Song edit refused because it would overlap other Songs.
    @Published private(set) var refusedEdit: RefusedEdit?
    /// Each Action's last send, and each Destination's.
    @Published private(set) var sendResults: [ActionID: SendResult] = [:]
    @Published private(set) var destinationSends: [DestinationID: SendResult] = [:]
    /// Songs that fired since the last Stop or disarm.
    @Published private(set) var firedThisRun: Set<SongID> = []
    @Published private(set) var lastFiring: Firing?
    /// The last timecode each source sent, for the Timecode screen's readouts.
    @Published private(set) var sourceReadings: [SourceRole: Timecode] = [:]
    /// LTC input peak level, 0...1.
    @Published private(set) var ltcLevel: Float = 0
    /// The Set being opened, while the opening screen shows.
    @Published var openingSetName: String?
    @Published var showingWelcome = false
    @Published var showingNewSetSetup = false

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
    /// Separate from `midiInput` so notes can come from a different port than MTC.
    private let noteInput = MIDIInput()
    private var noteParser = MIDIParser()
    private let artNetInput = ArtNetTimecodeInput()
    private let destinationChecker = DestinationChecker()
    private var timer: Timer?
    private var lastFedTimecode: Timecode?
    /// The daily log files in ~/Library/Logs/TrigIT, kept 30 days.
    private let showLog = ShowLog(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TrigIT", isDirectory: true))
    private var showLogFile: URL?
    /// Whether the operator chose to let the Simulator drive the show while
    /// Armed. Never remembered across launches, and cleared on disarming.
    private var simulatorAllowedWhileArmed = false
    private static let sourcesKey = "TrigIT.sources"

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
        noteInput.onBytes = { [weak self] bytes, _ in self?.receiveNotes(bytes) }
        midiOutput.onOutputsChanged = { [weak self] in
            guard let self else { return }
            self.midiOutputs = self.midiOutput.outputs()
        }
        midiOutputs = midiOutput.outputs()
        dmxStreamer.onError = { [weak self] message in self?.record(message, isError: true) }
        ltcInput.onLevel = { [weak self] level in self?.ltcLevel = level }
        dmxStreamer.update(for: set)
        artNetInput.onPacket = { [weak self] packet, time in self?.receiveArtNet(packet, at: time) }
        if let status = midiInput.startError { record("MIDI is unavailable (error \(status))", isError: true) }
        restoreSources()
        openLastDocument()
        // TrigIT may have been relaunched mid-show: follow the show straight away.
        setArmed(true)
        startClock()
        startDestinationChecks()
    }

    var currentSong: Song? {
        self.set.songs.first { $0.id == currentSongID }
    }

    // MARK: Armed

    func setArmed(_ armed: Bool) {
        if armed, simulator.isPlaying, !allowSimulatorWhileArmed(arming: true) { stop() }
        apply(engine.setArmed(armed))
        if !armed {
            simulatorAllowedWhileArmed = false
            midiOutput.releaseAllNotes()
            firedThisRun = []
        }
    }

    /// The Simulator only drives the show while Armed if the operator says so.
    /// Returns whether it may.
    private func allowSimulatorWhileArmed(arming: Bool = false) -> Bool {
        guard arming || isArmed, role(of: .simulator) != nil, !simulatorAllowedWhileArmed else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Use the Simulator as the live timecode while Armed?"
        alert.informativeText = "Songs it plays through will fire and send their Actions to real devices."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use the Simulator")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        simulatorAllowedWhileArmed = true
        record("The Simulator drives the show while Armed")
        return true
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
        record(text, timecode: nil, kind: isError ? .problem : .info)
    }

    func record(_ text: String, kind: LogEntry.Kind) {
        record(text, timecode: nil, kind: kind)
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
        guard song.hasTrigger else {
            refusedEdit = RefusedEdit(songID: song.id, conflicts: [],
                                      message: "\(song.name) needs a timecode span, a Start Note or a Stop Note; not changed")
            return false
        }
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
        addAction(kind.message, to: songID, list: list, canUse: kind.canUse)
    }

    /// Adds the ordinary Action a Resolume or grandMA3 preset fills in.
    func addAction(_ preset: ActionPreset, to songID: SongID, list: ActionList) {
        addAction(preset.message, to: songID, list: list)
    }

    /// Adds an OSC or MIDI Action, such as one Learn captured.
    func addAction(_ message: Action.Message, to songID: SongID, list: ActionList) {
        addAction(message, to: songID, list: list) { !message.isMIDI || $0.midiOutput != nil }
    }

    private func addAction(_ message: Action.Message, to songID: SongID, list: ActionList,
                           canUse: (Destination) -> Bool) {
        guard var song = song(songID) else { return }
        // Prefer a Destination that can carry it: a MIDI output for MIDI, DMX for pulses.
        let destination = set.destinations.first(where: canUse) ?? set.destinations.first
        guard let destination else { return }
        song[keyPath: list.keyPath].append(Action(destinationID: destination.id, message: message))
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

    /// Changes a Destination, or adds it if the Set doesn't have it yet.
    func update(_ destination: Destination) {
        edit { set in
            guard let index = set.destinations.firstIndex(where: { $0.id == destination.id }) else {
                return set.destinations.append(destination)
            }
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

    private func startDestinationChecks() {
        destinationChecker.start(inputs: { [weak self] in
            guard let self else { return nil }
            // Loopback is always present, so an empty list means "not known yet".
            let interfaces = self.networkInterfaces.isEmpty ? nil : Set(self.networkInterfaces.map(\.name))
            return .init(set: self.set, interfaces: interfaces, midiOutputs: Set(self.midiOutputs.map(\.uniqueID)))
        }, onUpdate: { [weak self] statuses, changes in
            guard let self else { return }
            if statuses != self.destinationStatuses { self.destinationStatuses = statuses }
            for change in changes where change.new.isOffline || change.old.isOffline {
                self.record("\(change.name): \(Self.statusText(change.new))", isError: change.new.isOffline)
            }
        }, onListenerError: { [weak self] message in self?.record(message, isError: true) })
    }

    /// How a Destination's status reads on the show screen, the banner and the log.
    static func statusText(_ status: DestinationStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .online: return "online"
        case .offline(.notResponding): return "offline, not responding"
        case .offline(.interfaceMissing(let name)): return "offline, network interface \(name) is gone"
        case .offline(.midiOutputMissing(let name)): return "offline, MIDI output \(name) is gone"
        }
    }

    func destinationName(_ id: DestinationID) -> String {
        set.destination(id)?.name ?? "missing Destination"
    }

    // MARK: Timecode Source

    /// Chooses the Primary Source. A Backup of the same kind is dropped,
    /// since each kind has one input.
    func selectSource(_ choice: TimecodeSourceChoice) {
        guard choice != source else { return }
        if choice == .simulator, simulator.isPlaying, !allowSimulatorWhileArmed() { return }
        source = choice
        record("Primary Source: \(sourceLabel(choice))")
        if backupSource?.kind == choice.kind {
            backupSource = nil
            record("Backup Source: none")
        }
        saveSources()
        restartInputs()
    }

    /// Chooses the Backup Source, or none. It must be a different kind than the Primary.
    func selectBackupSource(_ choice: TimecodeSourceChoice?) {
        guard choice != backupSource, choice?.kind != source.kind else { return }
        if choice == .simulator, simulator.isPlaying, !allowSimulatorWhileArmed() { return }
        backupSource = choice
        record("Backup Source: \(choice.map(sourceLabel) ?? "none")")
        saveSources()
        restartInputs()
    }

    private struct SavedSources: Codable {
        var primary: TimecodeSourceChoice
        var backup: TimecodeSourceChoice?
        var noteSourceID: Int32?
    }

    /// Remembers the sources, so a relaunch carries on following the same timecode.
    private func saveSources() {
        let saved = SavedSources(primary: source, backup: backupSource, noteSourceID: noteSourceID)
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.sourcesKey)
    }

    private func restoreSources() {
        guard let data = UserDefaults.standard.data(forKey: Self.sourcesKey),
              let saved = try? JSONDecoder().decode(SavedSources.self, from: data) else { return }
        source = saved.primary
        backupSource = saved.backup
        noteSourceID = saved.noteSourceID
        restartInputs()
        if noteSourceID != nil { startNotes() }
    }

    /// The chosen source of a kind, if the Primary or Backup is of that kind.
    private func choice(of kind: TimecodeSourceKind) -> TimecodeSourceChoice? {
        [source, backupSource].lazy.compactMap { $0 }.first { $0.kind == kind }
    }

    /// Whether readings of a kind come from the Primary or the Backup, or neither.
    private func role(of kind: TimecodeSourceKind) -> SourceRole? {
        if source.kind == kind { return .primary }
        return backupSource?.kind == kind ? .backup : nil
    }

    private func restartInputs() {
        ltcInput.stop()
        midiInput.disconnect()
        artNetInput.stop()
        lastFedTimecode = nil
        if choice(of: .ltc) != nil { startLTC() }
        if choice(of: .mtc) != nil { startMTC() }
        if choice(of: .artNet) != nil { startArtNet() }
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
        guard case .artNet(let interface) = choice(of: .artNet) else { return }
        do {
            try artNetInput.start(interface: interface)
        } catch {
            record("Art-Net Timecode input failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func receiveArtNet(_ packet: [UInt8], at time: Double) {
        guard let role = role(of: .artNet), let artTimeCode = ArtTimeCode(packet: packet),
              let timecode = Timecode(artTimeCode.fields) else { return }
        feed(TimecodeReading(timecode: timecode, frameRate: artTimeCode.frameRate, source: .artNet, timestamp: time), from: role)
    }

    private func startMTC() {
        guard case .mtc(let id) = choice(of: .mtc) else { return }
        midiParser = MIDIParser()
        mtcDecoder = MTCDecoder()
        if !midiInput.connect(to: id) {
            record("MTC source is not connected; waiting for it", isError: true)
        }
    }

    private func midiSourcesChanged() {
        midiSources = midiInput.sources()
        // The chosen source may have come back or gone; reconnect either way.
        if choice(of: .mtc) != nil { startMTC() }
        if noteSourceID != nil { startNotes() }
    }

    /// Chooses the MIDI source for Start and Stop Notes, or none.
    func selectNoteSource(_ id: Int32?) {
        guard id != noteSourceID else { return }
        noteSourceID = id
        record("MIDI notes: \(noteSourceLabel(id))")
        saveSources()
        startNotes()
    }

    func noteSourceLabel(_ id: Int32?) -> String {
        guard let id else { return "None" }
        return midiSources.first { $0.uniqueID == id }?.name ?? "missing MIDI source"
    }

    private func startNotes() {
        noteInput.disconnect()
        noteParser = MIDIParser()
        guard let id = noteSourceID else { return }
        if !noteInput.connect(to: id) {
            record("MIDI note source is not connected; waiting for it", isError: true)
        }
    }

    private func receiveNotes(_ bytes: [UInt8]) {
        for message in noteParser.parse(bytes) {
            apply(engine.handleMIDI(message))
        }
    }

    private func receiveMIDI(_ bytes: [UInt8], at time: Double) {
        guard let role = role(of: .mtc) else { return }
        for message in midiParser.parse(bytes) {
            guard let mtc = mtcDecoder.receive(message), let timecode = Timecode(mtc.fields) else { continue }
            feed(TimecodeReading(timecode: timecode, frameRate: mtc.frameRate, source: .mtc, timestamp: time), from: role)
        }
    }

    private func startLTC() {
        guard case .ltc(let uid, let channel) = choice(of: .ltc) else { return }
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
        if choice(of: .artNet) != nil, names != Set(interfaces.map(\.name)) { startArtNet() }
    }

    private func audioDevicesChanged() {
        audioInputDevices = audioDevices.inputDevices()
        // The chosen device may have come back or gone; reopen it either way.
        if choice(of: .ltc) != nil {
            ltcInput.stop()
            startLTC()
        }
    }

    private func receive(_ frame: LTCFrame, at time: Double) {
        guard let role = role(of: .ltc),
              let timecode = Timecode(hours: frame.hours, minutes: frame.minutes, seconds: frame.seconds, frames: frame.frames)
        else { return }
        feed(TimecodeReading(timecode: timecode, frameRate: frame.frameRate, source: .ltc, timestamp: time), from: role)
    }

    // MARK: Simulator

    func play(from position: Timecode? = nil) {
        guard allowSimulatorWhileArmed() else { return }
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
        if let role = role(of: .simulator), !isArmed || simulatorAllowedWhileArmed, let reading = simulator.reading(at: now), reading.timecode != lastFedTimecode {
            lastFedTimecode = reading.timecode
            feed(reading, from: role)
        }
        apply(engine.tick(at: now))
    }

    private func feed(_ reading: TimecodeReading, from role: SourceRole) {
        sourceReadings[role] = reading.timecode
        apply(engine.handle(reading, from: role))
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
            firedThisRun.insert(id)
            lastFiring = Firing(songID: id, date: Date(), actionIDs: song(id)?.startActions.map(\.id) ?? [],
                                sent: isArmed || cause == .manual)
            switch cause {
            case .manual: record("Fired \(name) by hand", kind: .fired)
            case .entering, .note:
                let how = cause == .note ? " by its Start Note" : ""
                record(isArmed ? "Fired \(name)\(how)" : "Fired \(name)\(how) (disarmed, nothing sent)", kind: .fired)
            }
        case .ended(let id, let cause):
            let name = song(id)?.name ?? "?"
            let how: String
            switch cause {
            case .stop: how = "timecode stopped"
            case .playedPastEnd: how = "played past its end"
            case .note: how = "its Stop Note"
            case .manual: how = "Fire stop by hand"
            }
            let sends = cause != .manual && !isArmed && !(song(id)?.stopActions.isEmpty ?? true) ? ", disarmed, nothing sent" : ""
            record("\(name) ended (\(how)\(sends))", kind: .stop)
        case .stopped:
            firedThisRun = []
            record("Timecode stopped", kind: .stop)
        case .dropout(let seconds):
            record("Timecode dropout: \(Int((seconds * 1000).rounded())) ms gap", kind: .dropout)
        case .send(let outgoing):
            send(outgoing)
        case .missingDestination(let songID, _):
            record("\(song(songID)?.name ?? "?"): Action skipped, its Destination was deleted", isError: true)
        case .armedChanged(let armed):
            isArmed = armed
            record(armed ? "Armed" : "Disarmed", kind: armed ? .armed : .disarmed)
            if armed { markCurrentVersionUsedInShow() }
        case .jumped:
            break
        case .sourceHealthChanged(let role, let healthy):
            if healthy { healthySources.insert(role) } else { healthySources.remove(role) }
        case .liveSourceChanged(let role):
            liveSource = role
            record("Switched to the \(roleLabel(role)): \(sourceLabel(for: role))", kind: .failover)
        case .alertChanged(let newAlert):
            alert = newAlert
            if let newAlert {
                record(alertText(newAlert), isError: true)
            } else if liveSource == .backup {
                record("Primary Source is back; staying on the Backup until the next Stop")
            } else if !engine.isStopped {
                record("Timecode is back")
            }
        }
    }

    func roleLabel(_ role: SourceRole) -> String {
        role == .primary ? "Primary Source" : "Backup Source"
    }

    /// The label of the source playing a role ("none" for a missing Backup).
    func sourceLabel(for role: SourceRole) -> String {
        guard let choice = role == .primary ? source : backupSource else { return "none" }
        return sourceLabel(choice)
    }

    /// The banner's lines: the timecode alert, then each offline Destination.
    var alertLines: [String] {
        let offline = set.destinations.compactMap { destination -> String? in
            guard let status = destinationStatuses[destination.id], status.isOffline else { return nil }
            return "\(destination.name) \(Self.statusText(status))"
        }
        return (alert.map { [alertText($0)] } ?? []) + offline
    }

    /// What the banner and the fire log say for an alert.
    func alertText(_ alert: TimecodeAlert) -> String {
        switch alert {
        case .primaryLostRunningOnBackup:
            return "Primary \(source.kindName) lost. Following Backup \(backupSource?.kindName ?? "Source")."
        case .allTimecodeLost:
            let kinds = [source, backupSource].compactMap { $0?.kindName }.joined(separator: " or ")
            return "No timecode from \(kinds). Holding the last frame."
        }
    }

    /// Writes the fire log to a CSV file the operator chooses.
    func exportLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(set.name) Fire Log.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let quote = { (text: String) in "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let lines = ["time,timecode,event,detail"] + log.reversed().map { entry in
            [formatter.string(from: entry.date), entry.timecode?.description ?? "", entry.kind.rawValue, quote(entry.text)]
                .joined(separator: ",")
        }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            record("Couldn't export the Fire Log: \(error.localizedDescription)", isError: true)
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
        deliver(outgoing.action.message, actionID: outgoing.action.id, to: destination, summary: summary)
    }

    /// Sends one Action now, Armed or not, and logs it as a test.
    func test(_ action: Action, in songID: SongID) {
        let songName = song(songID)?.name ?? "?"
        guard let destination = set.destination(action.destinationID) else {
            record("Test: \(songName): Action not sent, its Destination was deleted", isError: true)
            return
        }
        deliver(action.message, actionID: action.id, to: destination,
                summary: "Test: \(songName) → \(destination.name): \(Self.describe(action.message))")
    }

    private func deliver(_ message: Action.Message, actionID: ActionID?, to destination: Destination, summary: String) {
        let timecode = playhead
        let finish = { [weak self] (error: String?) in
            guard let self else { return }
            let result = SendResult(date: Date(), timecode: timecode, ok: error == nil, errorText: error)
            if let actionID { self.sendResults[actionID] = result }
            self.destinationSends[destination.id] = result
            if let error {
                self.record("\(summary) failed: \(error)", timecode: timecode, kind: .failed)
            } else {
                self.record(summary, timecode: timecode, kind: .sent)
            }
        }
        switch message {
        case .osc(let message):
            guard message.hasValidAddress else { return finish("invalid OSC address") }
            sender.send(message.encoded(), to: destination) { error in finish(error?.localizedDescription) }
        case .midiNote(let note):
            sendMIDI(to: destination, finish) { try midiOutput.play(note, on: $0) }
        case .msc(let command):
            guard command.isValid else {
                return finish("cue and list must be numbers like 5 or 12.5, and a list needs a cue")
            }
            sendMIDI(to: destination, finish) { try midiOutput.send(command.encoded, to: $0) }
        case .dmxPulse(let pulse):
            do {
                try dmxStreamer.play(pulse, to: destination)
                finish(nil)
            } catch {
                finish(error.localizedDescription)
            }
        }
    }

    private func sendMIDI(to destination: Destination, _ finish: (String?) -> Void, _ send: (MIDIPortReference) throws -> Void) {
        guard let output = destination.midiOutput else {
            return finish("\(destination.name) has no MIDI output")
        }
        do {
            try send(output)
            finish(nil)
        } catch {
            finish(error.localizedDescription)
        }
    }

    /// Sends a test OSC message to a Destination, for New Set setup.
    func testDestination(_ destination: Destination) {
        deliver(.osc(OSCMessage(address: "/trigit/test")), actionID: nil, to: destination,
                summary: "Test: \(destination.name)")
    }

    /// Whether a Destination is Reachable, No reply or Idle: the ping monitor
    /// says offline, or the last send to it failed, is No reply.
    enum Reachability { case reachable, noReply, idle }

    func reachability(of id: DestinationID) -> Reachability {
        if destinationStatuses[id]?.isOffline == true || destinationSends[id]?.ok == false { return .noReply }
        if destinationStatuses[id] == .online || destinationSends[id]?.ok == true { return .reachable }
        return .idle
    }

    /// The Show screen's status bar line about the last firing, and whether
    /// any Action failed (nil: disarmed, nothing was sent).
    var lastFiringSummary: (text: String, failed: Bool?)? {
        guard let firing = lastFiring, let name = song(firing.songID)?.name else { return nil }
        let total = firing.actionIDs.count
        guard firing.sent else { return ("\(name) fired, disarmed, nothing sent", nil) }
        let failed = firing.actionIDs.filter { id in
            guard let result = sendResults[id], result.date >= firing.date else { return false }
            return !result.ok
        }.count
        if failed > 0 { return ("\(name): \(failed) of \(total) Actions failed", true) }
        return ("\(name) fired \(total) of \(total) Action\(total == 1 ? "" : "s")", false)
    }

    /// Where the Playhead is in the Set, if it is known.
    var progress: ShowProgress? {
        guard let playhead else { return nil }
        return ShowProgress(set: set, playhead: playhead, rate: frameRate ?? simulator.frameRate)
    }

    /// Jumps the Simulator five seconds before a Song and plays.
    func rehearse(_ song: Song) {
        let rate = simulator.frameRate
        let index = max(0, song.start.frameIndex(at: rate) - 5 * rate.nominalFramesPerSecond)
        jump(to: Timecode(frameIndex: index, rate: rate))
        if !simulator.isPlaying { play() }
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

    private func record(_ text: String, timecode: Timecode??, kind: LogEntry.Kind) {
        let entry = LogEntry(timecode: timecode ?? playhead, text: text, kind: kind)
        log.insert(entry, at: 0)
        if log.count > Self.maxLogEntries { log.removeLast() }
        writeToShowLog(entry)
    }

    private func writeToShowLog(_ entry: LogEntry) {
        let file = showLog.fileURL(for: entry.date)
        if file != showLogFile {
            showLogFile = file
            showLog.removeOldFiles(now: entry.date)
        }
        let line = [entry.timecode?.description ?? "--:--:--:--", entry.isError ? "!" : " ", entry.kind.rawValue, entry.text].joined(separator: "  ")
        try? showLog.append(line, at: entry.date)
    }

    private func nextFreeHour() -> Timecode {
        let lastHour = set.songs.filter(\.hasSpan).map(\.end.hours).max() ?? 0
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
