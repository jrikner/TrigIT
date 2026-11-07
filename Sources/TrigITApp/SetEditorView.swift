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
                HStack {
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Start").frame(width: 110, alignment: .leading)
                    Text("End").frame(width: 110, alignment: .leading)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)

                List(selection: $selection) {
                    ForEach(model.set.songs) { song in
                        SongRow(song: song, isCurrent: song.id == model.currentSongID)
                            .tag(song.id)
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

struct SongRow: View {
    @EnvironmentObject private var model: ShowModel
    let song: Song
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(isCurrent ? Color.green : Color.clear)
                    .frame(width: 8, height: 8)
                Group {
                TextField("Name", text: Binding(
                    get: { song.name },
                    set: { name in
                        var edited = song
                        edited.name = name
                        model.update(edited)
                    }
                ))
                TimecodeField(value: song.start) { start in
                    var edited = song
                    edited.start = start
                    return model.update(edited)
                }
                TimecodeField(value: song.end) { end in
                    var edited = song
                    edited.end = end
                    return model.update(edited)
                }
                }
                .disabled(model.isShowLocked)

                // Manual firing works under Show Lock and while disarmed.
                Button {
                    model.fire(song.id)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Fire: send this Song's Start Actions now, even if disarmed")
                Button {
                    model.fireStop(song.id)
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .disabled(song.stopActions.isEmpty)
                .opacity(song.stopActions.isEmpty ? 0.2 : 1)
                .help("Fire stop: send this Song's Stop Actions now, even if disarmed")
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
                Picker("", selection: $list) {
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
            Picker("", selection: Binding(
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
            .frame(width: 130)

            switch action.message {
            case .osc(let message):
                OSCActionFields(message: message) { update(.osc($0)) }
            case .midiNote(let note):
                MIDINoteFields(note: note) { update(.midiNote($0)) }
            case .msc(let command):
                MSCFields(command: command) { update(.msc($0)) }
            }

            if action.message.isMIDI, model.set.destination(action.destinationID)?.midiOutput == nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help("This Destination has no MIDI output; set one in the Destinations tab")
            }

            Button(role: .destructive) {
                model.deleteAction(action.id, in: songID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this Action")
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
        TextField("/osc/address", text: Binding(
            get: { message.address },
            set: { address in
                var edited = message
                edited.address = address
                onChange(edited)
            }
        ))
        .font(.system(.body, design: .monospaced))
        .foregroundColor(message.hasValidAddress ? .primary : .red)

        TextField("arguments", text: Binding(
            get: { argumentsText },
            set: { text in
                argumentsText = text
                if let arguments = OSCArgument.parseList(text) {
                    var edited = message
                    edited.arguments = arguments
                    onChange(edited)
                }
            }
        ))
        .font(.system(.body, design: .monospaced))
        .foregroundColor(OSCArgument.parseList(argumentsText) == nil ? .red : .primary)
        .frame(width: 140)
    }
}

struct MIDINoteFields: View {
    let note: MIDINote
    let onChange: (MIDINote) -> Void

    var body: some View {
        Text("Note").foregroundColor(.secondary)
        NumberField(value: Int(note.note), range: 0...127, width: 44) {
            onChange(MIDINote(channel: note.channel, note: UInt8($0), velocity: note.velocity))
        }
        Text(note.noteName).font(.system(.body, design: .monospaced)).frame(width: 40, alignment: .leading)
        Text("Ch").foregroundColor(.secondary)
        NumberField(value: Int(note.channel) + 1, range: 1...16, width: 36) {
            onChange(MIDINote(channel: UInt8($0 - 1), note: note.note, velocity: note.velocity))
        }
        Text("Vel").foregroundColor(.secondary)
        NumberField(value: Int(note.velocity), range: 1...127, width: 44) {
            onChange(MIDINote(channel: note.channel, note: note.note, velocity: UInt8($0)))
        }
        Spacer(minLength: 0)
    }
}

struct MSCFields: View {
    let command: MSCCommand
    let onChange: (MSCCommand) -> Void

    var body: some View {
        Picker("", selection: Binding(
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
        TextField("next", text: Binding(
            get: { command.cue },
            set: { value in
                var edited = command
                edited.cue = value
                onChange(edited)
            }
        ))
        .frame(width: 56)
        Text("List").foregroundColor(.secondary)
        TextField("default", text: Binding(
            get: { command.list },
            set: { value in
                var edited = command
                edited.list = value
                onChange(edited)
            }
        ))
        .frame(width: 56)
        Text("Device").foregroundColor(.secondary)
        NumberField(value: Int(command.deviceID), range: 0...127, width: 40) { id in
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

/// A small whole-number field. Values outside `range` turn red and are not applied.
struct NumberField: View {
    let value: Int
    let range: ClosedRange<Int>
    let width: CGFloat
    let onCommit: (Int) -> Void
    @State private var text: String

    init(value: Int, range: ClosedRange<Int>, width: CGFloat, onCommit: @escaping (Int) -> Void) {
        self.value = value
        self.range = range
        self.width = width
        self.onCommit = onCommit
        _text = State(initialValue: String(value))
    }

    private var parsed: Int? { Int(text).flatMap { range.contains($0) ? $0 : nil } }

    var body: some View {
        TextField("", text: Binding(
            get: { text },
            set: { newText in
                text = newText
                if let parsed { onCommit(parsed) }
            }
        ))
        .font(.system(.body, design: .monospaced))
        .foregroundColor(parsed == nil ? .red : .primary)
        .frame(width: width)
        .onChange(of: value) { text = String($0) }
    }
}
