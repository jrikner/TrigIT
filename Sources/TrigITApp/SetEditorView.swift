import AppKit
import SwiftUI
import TrigITEngine
import TrigITProtocols
import UniformTypeIdentifiers

/// The Song list, with the selected Song's Start Actions below it.
struct SetEditorView: View {
    @EnvironmentObject private var model: ShowModel
    @State private var selection: SongID?
    @State private var importReport: ImportSummary?

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.set.name).font(.headline)
                    if model.isShowLocked {
                        Label("Locked", systemImage: "lock.fill").foregroundColor(.orange)
                    }
                    Spacer()
                    Button("Import CSV…") { importCSV() }
                    Button("Add Song") { model.addSong() }
                    Button("Delete") {
                        if let selection { model.deleteSong(selection) }
                        selection = nil
                    }
                    .disabled(selection == nil)
                }
                .disabled(model.isShowLocked)

                HStack {
                    Text("Capture from the Playhead:").foregroundColor(.secondary)
                    Button("Set start") { if let selection { model.captureStart(for: selection) } }
                    Button("Set end") { if let selection { model.captureEnd(for: selection) } }
                    Spacer()
                }
                .font(.callout)
                .disabled(model.isShowLocked || selection == nil || model.playhead == nil)

                HStack {
                    Text("Stop time:").foregroundColor(.secondary)
                    Stepper(value: Binding(get: { model.set.stopTime }, set: { model.setStopTime($0) }),
                            in: ShowSet.stopTimeRange, step: 0.5) {
                        Text(String(format: "%.1f s", model.set.stopTime))
                            .font(.system(.body, design: .monospaced))
                    }
                    .help("Timecode silent for longer than this counts as a Stop: the current Song ends and re-arms. Shorter gaps are dropouts and never re-fire.")
                    Spacer()
                }
                .font(.callout)
                .disabled(model.isShowLocked)

                if let refused = model.refusedEdit {
                    Text(refused.message)
                        .font(.callout)
                        .foregroundColor(.orange)
                }
                List(selection: $selection) {
                    Section {
                        ForEach(model.set.songs) { song in
                            SongRow(song: song, isCurrent: song.id == model.currentSongID)
                                .tag(song.id)
                        }
                    } header: {
                        SongHeader()
                    }
                }
            }
            .padding(8)
            .frame(minHeight: 180)

            Group {
                if let selection, let song = model.song(selection) {
                    ActionsEditor(song: song)
                } else {
                    Text("Select a Song to edit its Actions")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(8)
            .frame(minHeight: 160)
        }
        .sheet(item: $importReport) { summary in
            ImportReportView(summary: summary)
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a CSV file with the columns name, start, end (hh:mm:ss:ff)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            importReport = ImportSummary(fileName: url.lastPathComponent, report: nil)
            return
        }
        let report = model.importSongs(csv: text, fileName: url.lastPathComponent)
        importReport = ImportSummary(fileName: url.lastPathComponent, report: report)
    }
}

struct ImportSummary: Identifiable {
    let id = UUID()
    let fileName: String
    /// nil if the file couldn't be read.
    let report: SongImportReport?
}

struct ImportReportView: View {
    @Environment(\.dismiss) private var dismiss
    let summary: ImportSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from \(summary.fileName)").font(.headline)
            if let report = summary.report {
                Text("Added \(report.imported.count) Song\(report.imported.count == 1 ? "" : "s").")
                if report.problems.isEmpty {
                    Text("Every row was imported.").foregroundColor(.secondary)
                } else {
                    Text("Skipped \(report.problems.count) row\(report.problems.count == 1 ? "" : "s"):")
                        .foregroundColor(.orange)
                    List(report.problems, id: \.self) { problem in
                        Text("Line \(problem.line): \(problem.reason.description)")
                    }
                    .frame(minHeight: 120)
                }
            } else {
                Text("The file could not be read as text.").foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

/// Column titles laid out exactly like a `SongRow`'s first line, so they line up.
struct SongHeader: View {
    var body: some View {
        HStack {
            SongRow.currentMarker(false)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Start").frame(width: TimecodeField.width, alignment: .leading)
            Text("End").frame(width: TimecodeField.width, alignment: .leading)
            SongRow.fireButtons(fire: {}, fireStop: {}, canStop: true).hidden()
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}

struct SongRow: View {
    @EnvironmentObject private var model: ShowModel
    let song: Song
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Self.currentMarker(isCurrent)
                Group {
                TextField("Name", text: Binding(
                    get: { song.name },
                    set: { name in
                        var edited = song
                        edited.name = name
                        model.update(edited)
                    }
                ))
                TimecodeField("Start", value: song.start) { start in
                    var edited = song
                    edited.start = start
                    return model.update(edited)
                }
                TimecodeField("End", value: song.end) { end in
                    var edited = song
                    edited.end = end
                    return model.update(edited)
                }
                }
                .disabled(model.isShowLocked)

                // Manual firing works under Show Lock and while disarmed.
                Self.fireButtons(fire: { model.fire(song.id) },
                                 fireStop: { model.fireStop(song.id) },
                                 canStop: !song.stopActions.isEmpty)
            }
            HStack {
                Text(actionSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if song.end < song.start {
                    Text("End is before start: this Song never fires")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(.leading, 16)
        }
        .padding(.vertical, 2)
        .fontWeight(isCurrent ? .bold : .regular)
        .background(isInConflict ? Color.orange.opacity(0.25) : Color.clear)
    }

    static func currentMarker(_ isCurrent: Bool) -> some View {
        Circle()
            .fill(isCurrent ? Color.green : Color.clear)
            .frame(width: 8, height: 8)
            .accessibilityLabel("Current Song")
            .accessibilityHidden(!isCurrent)
    }

    static func fireButtons(fire: @escaping () -> Void, fireStop: @escaping () -> Void, canStop: Bool) -> some View {
        HStack {
            Button(action: fire) {
                Label("Fire", systemImage: "play.fill").labelStyle(.iconOnly)
            }
            .help("Fire: send this Song's Start Actions now, even if disarmed")
            Button(action: fireStop) {
                Label("Fire Stop", systemImage: "stop.fill").labelStyle(.iconOnly)
            }
            .disabled(!canStop)
            .help("Fire stop: send this Song's Stop Actions now, even if disarmed")
        }
        .buttonStyle(.borderless)
    }

    private var actionSummary: String {
        let start = song.startActions.isEmpty ? "No Start Actions" : "\(song.startActions.count) Start Action(s)"
        return song.stopActions.isEmpty ? start : start + ", \(song.stopActions.count) Stop Action(s)"
    }

    /// Part of the last refused edit: the Song being edited or one in its way.
    private var isInConflict: Bool {
        guard let refused = model.refusedEdit else { return false }
        return refused.songID == song.id || refused.conflicts.contains(song.id)
    }
}

// MARK: - Actions

/// The selected Song's Start Actions and Stop Actions.
struct ActionsEditor: View {
    @EnvironmentObject private var model: ShowModel
    let song: Song
    @State private var list: ShowModel.ActionList = .start

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(song.name).font(.headline)
                Picker("Action list", selection: $list) {
                    Text("Start Actions (\(song.startActions.count))").tag(ShowModel.ActionList.start)
                    Text("Stop Actions (\(song.stopActions.count))").tag(ShowModel.ActionList.stop)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                Spacer()
                Menu("Add Action") {
                    ForEach(ShowModel.NewActionKind.allCases, id: \.self) { kind in
                        Button(kind.label) { model.addAction(kind, to: song.id, list: list) }
                    }
                }
                .fixedSize()
                .disabled(model.set.destinations.isEmpty || model.isShowLocked)
            }
            if model.set.destinations.isEmpty {
                Text("Add a Destination first (Destinations tab).")
                    .foregroundColor(.secondary)
            }
            Text(list == .start
                 ? "Sent in this order when the Song is entered."
                 : "Sent in this order when the Song ends: timecode stops inside it, or plays on past its end. Usually empty; for DJ pull-ups.")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Drag to reorder. Arguments: 1 is an int, 0.5 a float, text a string; \"quote\" strings with spaces.")
                .font(.caption)
                .foregroundColor(.secondary)
            List {
                ForEach(song[keyPath: list.keyPath]) { action in
                    ActionRow(songID: song.id, action: action)
                        .disabled(model.isShowLocked)
                }
                // No dragging to reorder while Show Lock is on.
                .onMove(perform: model.isShowLocked ? nil : { offsets, destination in
                    model.moveActions(in: song.id, list: list, from: offsets, to: destination)
                })
            }
        }
    }
}

struct ActionRow: View {
    @EnvironmentObject private var model: ShowModel
    let songID: SongID
    let action: Action

    var body: some View {
        HStack {
            Picker("Destination", selection: Binding(
                get: { action.destinationID },
                set: { id in
                    var edited = action
                    edited.destinationID = id
                    model.update(edited, in: songID)
                }
            )) {
                ForEach(model.set.destinations) { destination in
                    Text(destination.name).tag(destination.id)
                }
            }
            .labelsHidden()
            .frame(minWidth: 90, idealWidth: 130, maxWidth: 130)

            switch action.message {
            case .osc(let message):
                OSCActionFields(message: message) { update(.osc($0)) }
            case .midiNote(let note):
                MIDINoteFields(note: note) { update(.midiNote($0)) }
            case .msc(let command):
                MSCFields(command: command) { update(.msc($0)) }
            case .dmxPulse(let pulse):
                DMXPulseFields(pulse: pulse) { update(.dmxPulse($0)) }
            }

            if let problem = transportProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help(problem)
                    .accessibilityLabel(problem)
            }

            Button(role: .destructive) {
                model.deleteAction(action.id, in: songID)
            } label: {
                Label("Delete Action", systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Delete this Action")
        }
    }

    /// Why this Action's Destination can't carry it, if it can't.
    private var transportProblem: String? {
        guard let destination = model.set.destination(action.destinationID) else { return nil }
        switch action.message {
        case .osc:
            return nil
        case .midiNote, .msc:
            return destination.midiOutput == nil ? "This Destination has no MIDI output; set one in the Destinations tab" : nil
        case .dmxPulse(let pulse):
            guard let output = destination.dmxOutput else {
                return "This Destination has no Art-Net or sACN output; set one in the Destinations tab"
            }
            return output.universeRange.contains(pulse.universe)
                ? nil : "Universe \(pulse.universe) is outside \(output.name)'s range \(output.universeRange.lowerBound)-\(output.universeRange.upperBound)"
        }
    }

    private func update(_ message: Action.Message) {
        var edited = action
        edited.message = message
        model.update(edited, in: songID)
    }
}

struct OSCActionFields: View {
    let message: OSCMessage
    let onChange: (OSCMessage) -> Void
    @State private var argumentsText: String

    init(message: OSCMessage, onChange: @escaping (OSCMessage) -> Void) {
        self.message = message
        self.onChange = onChange
        _argumentsText = State(initialValue: message.arguments.map(\.description).joined(separator: " "))
    }

    var body: some View {
        TextField("OSC address", text: Binding(
            get: { message.address },
            set: { address in
                var edited = message
                edited.address = address
                onChange(edited)
            }
        ), prompt: Text("/osc/address"))
        .labelsHidden()
        .font(.system(.body, design: .monospaced))
        .foregroundColor(message.hasValidAddress ? .primary : .red)
        .frame(minWidth: 80)

        TextField("OSC arguments", text: Binding(
            get: { argumentsText },
            set: { text in
                argumentsText = text
                if let arguments = OSCArgument.parseList(text) {
                    var edited = message
                    edited.arguments = arguments
                    onChange(edited)
                }
            }
        ), prompt: Text("arguments"))
        .labelsHidden()
        .font(.system(.body, design: .monospaced))
        .foregroundColor(OSCArgument.parseList(argumentsText) == nil ? .red : .primary)
        .frame(minWidth: 70, idealWidth: 140, maxWidth: 140)
    }
}

struct MIDINoteFields: View {
    let note: MIDINote
    let onChange: (MIDINote) -> Void

    var body: some View {
        Text("Note").foregroundColor(.secondary)
        NumberField("MIDI note", value: Int(note.note), range: 0...127, width: 44) {
            onChange(MIDINote(channel: note.channel, note: UInt8($0), velocity: note.velocity))
        }
        Text(note.noteName).font(.system(.body, design: .monospaced)).frame(width: 40, alignment: .leading)
        Text("Ch").foregroundColor(.secondary)
        NumberField("MIDI channel", value: Int(note.channel) + 1, range: 1...16, width: 36) {
            onChange(MIDINote(channel: UInt8($0 - 1), note: note.note, velocity: note.velocity))
        }
        Text("Vel").foregroundColor(.secondary)
        NumberField("Velocity", value: Int(note.velocity), range: 1...127, width: 44) {
            onChange(MIDINote(channel: note.channel, note: note.note, velocity: UInt8($0)))
        }
        Spacer(minLength: 0)
    }
}

struct MSCFields: View {
    let command: MSCCommand
    let onChange: (MSCCommand) -> Void

    var body: some View {
        Picker("MSC command", selection: Binding(
            get: { command.command },
            set: { value in
                var edited = command
                edited.command = value
                onChange(edited)
            }
        )) {
            ForEach(MSCCommand.Command.allCases, id: \.self) { Text($0.name).tag($0) }
        }
        .labelsHidden()
        .frame(width: 90)
        Text("Cue").foregroundColor(.secondary)
        TextField("MSC cue", text: Binding(
            get: { command.cue },
            set: { value in
                var edited = command
                edited.cue = value
                onChange(edited)
            }
        ), prompt: Text("next"))
        .labelsHidden()
        .frame(width: 56)
        Text("List").foregroundColor(.secondary)
        TextField("MSC list", text: Binding(
            get: { command.list },
            set: { value in
                var edited = command
                edited.list = value
                onChange(edited)
            }
        ), prompt: Text("default"))
        .labelsHidden()
        .frame(width: 56)
        Text("Device").foregroundColor(.secondary)
        NumberField("MSC device ID", value: Int(command.deviceID), range: 0...127, width: 40) { id in
            var edited = command
            edited.deviceID = UInt8(id)
            onChange(edited)
        }
        .help("MSC device ID: 0-111 one device, 112-126 a group, 127 every device")
        if !command.isValid {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
                .help("Cue and list must be numbers like 5 or 12.5, and a list needs a cue")
        }
    }
}

struct DMXPulseFields: View {
    let pulse: DMXPulse
    let onChange: (DMXPulse) -> Void

    var body: some View {
        Text("Univ").foregroundColor(.secondary)
        NumberField("Universe", value: pulse.universe, range: 0...63_999, width: 52) { universe in
            onChange(DMXPulse(universe: universe, channel: pulse.channel, value: pulse.value, duration: pulse.duration))
        }
        .help("Art-Net: port-address 0-32767. sACN: universe 1-63999.")
        Text("Ch").foregroundColor(.secondary)
        NumberField("DMX channel", value: pulse.channel, range: 1...512, width: 40) { channel in
            onChange(DMXPulse(universe: pulse.universe, channel: channel, value: pulse.value, duration: pulse.duration))
        }
        Text("=").foregroundColor(.secondary)
        NumberField("DMX value", value: Int(pulse.value), range: 0...255, width: 40) { value in
            onChange(DMXPulse(universe: pulse.universe, channel: pulse.channel, value: UInt8(value), duration: pulse.duration))
        }
        Text("for").foregroundColor(.secondary)
        NumberField("Duration in milliseconds", value: Int((pulse.duration * 1000).rounded()), range: 50...10_000, width: 52) { milliseconds in
            onChange(DMXPulse(universe: pulse.universe, channel: pulse.channel, value: pulse.value,
                              duration: Double(milliseconds) / 1000))
        }
        Text("ms").foregroundColor(.secondary)
        Spacer(minLength: 0)
    }
}

/// A small whole-number field. Values outside `range` turn red and are not applied.
struct NumberField: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let width: CGFloat
    let onCommit: (Int) -> Void
    @State private var text: String

    init(_ label: String, value: Int, range: ClosedRange<Int>, width: CGFloat, onCommit: @escaping (Int) -> Void) {
        self.label = label
        self.value = value
        self.range = range
        self.width = width
        self.onCommit = onCommit
        _text = State(initialValue: String(value))
    }

    private var parsed: Int? { Int(text).flatMap { range.contains($0) ? $0 : nil } }

    var body: some View {
        TextField(label, text: Binding(
            get: { text },
            set: { newText in
                text = newText
                if let parsed { onCommit(parsed) }
            }
        ))
        .labelsHidden()
        .font(.system(.body, design: .monospaced))
        .foregroundColor(parsed == nil ? .red : .primary)
        .frame(width: width)
        .onChange(of: value) { text = String($0) }
    }
}
