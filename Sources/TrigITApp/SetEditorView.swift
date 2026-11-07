import AppKit
import SwiftUI
import TrigITEngine
import TrigITProtocols
import UniformTypeIdentifiers

/// The Song list on the left, the selected Song's Timing or Actions on the right.
struct SetEditorView: View {
    @EnvironmentObject private var model: ShowModel
    @State private var selection: SongID?
    @State private var importReport: ImportSummary?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.set.songs) { song in
                        SongListRow(song: song).tag(song.id)
                            .contextMenu {
                                Button("Delete Song") { delete(song.id) }.disabled(model.isShowLocked)
                            }
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand { if let selection { delete(selection) } }
                RowDivider()
                HStack {
                    Button { model.addSong(); selection = model.set.songs.last?.id } label: {
                        Label("Song", systemImage: "plus")
                    }
                    Button("Import CSV…") { importCSV() }
                    Spacer()
                    Button { if let selection { delete(selection) } } label: {
                        Label("Delete Song", systemImage: "minus").labelStyle(.iconOnly)
                    }
                    .disabled(selection == nil)
                    .help("Delete the selected Song")
                }
                .capsuleButton()
                .disabled(model.isShowLocked)
                .padding(12)
            }
            .frame(width: 340)
            .overlay(alignment: .trailing) { Rectangle().fill(Surface.hairline).frame(width: 1) }

            Group {
                if let selection, let song = model.song(selection) {
                    SongDetail(song: song).id(song.id)
                } else {
                    Text("Select a Song")
                        .font(TrigType.body)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = model.set.songs.first?.id } }
        .sheet(item: $importReport) { summary in
            ImportReportView(summary: summary)
        }
    }

    private func delete(_ id: SongID) {
        model.deleteSong(id)
        if selection == id { selection = nil }
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

/// A Song in the list: name, span or notes, and a warning if it overlaps.
struct SongListRow: View {
    @EnvironmentObject private var model: ShowModel
    let song: Song

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(song.name).font(TrigType.rowTitle).lineLimit(1)
                Text(subtitle).font(TrigType.secondary.monospacedDigit()).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(StateColor.caution)
                    .help(problem)
                    .accessibilityLabel(problem)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private var subtitle: String {
        if song.hasSpan { return "\(song.start) to \(song.end)" }
        if let note = song.startNote { return "Start Note, \(note.spoken)" }
        if let note = song.stopNote { return "Stop Note, \(note.spoken)" }
        return "No trigger"
    }

    private var problem: String? {
        if song.hasSpan && song.end < song.start { return "End is before start: this Song never fires" }
        guard let refused = model.refusedEdit, refused.songID == song.id || refused.conflicts.contains(song.id) else { return nil }
        return refused.message
    }
}

extension NoteTrigger {
    /// "channel 1, C3"
    var spoken: String {
        "channel \(channel + 1), \(MIDINote(channel: channel, note: note).noteName)"
    }
}

/// The selected Song: name, Fire and Stop, then its Timing or Actions.
struct SongDetail: View {
    @EnvironmentObject private var model: ShowModel
    let song: Song
    @SceneStorage("songTab") private var tab = "timing"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    TextField("Song name", text: Binding(get: { song.name }, set: { name in
                        var edited = song
                        edited.name = name
                        model.update(edited)
                    }))
                    .textFieldStyle(.plain)
                    .font(TrigType.pageTitle)
                    .disabled(model.isShowLocked)
                    // Manual firing works under Show Lock and while disarmed.
                    Button { model.fire(song.id) } label: { Label("Fire", systemImage: "play.fill") }
                        .capsuleButton()
                        .help("Fire: send this Song's Start Actions now, even if disarmed")
                    Button { model.fireStop(song.id) } label: { Label("Stop", systemImage: "stop.fill") }
                        .capsuleButton()
                        .disabled(song.stopActions.isEmpty)
                        .help("Stop: send this Song's Stop Actions now, even if disarmed")
                }
                Picker("View", selection: $tab) {
                    Text("Timing").tag("timing")
                    Text("Actions").tag("actions")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if tab == "timing" {
                    SongTimingEditor(song: song)
                } else {
                    SongActionsEditor(song: song)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 32, bottom: 28, trailing: 32))
        }
    }
}

// MARK: - Timing

struct SongTimingEditor: View {
    @EnvironmentObject private var model: ShowModel
    let song: Song
    @State private var learningNote: NoteField?

    enum NoteField: String, Identifiable {
        case start = "Start Note", stop = "Stop Note"
        var id: Self { self }
        var keyPath: WritableKeyPath<Song, NoteTrigger?> { self == .start ? \.startNote : \.stopNote }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                GroupHeader(title: "Timecode span") {
                    Toggle("Use a timecode span", isOn: Binding(get: { song.hasSpan }, set: { hasSpan in
                        var edited = song
                        edited.hasSpan = hasSpan
                        model.update(edited)
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Off: only the notes trigger this Song; its start and end are kept but ignored")
                }
                GroupedBox {
                    spanRow("Start", value: song.start, keyPath: \.start, capture: { model.captureStart(for: song.id) })
                    RowDivider()
                    spanRow("End", value: song.end, keyPath: \.end, capture: { model.captureEnd(for: song.id) })
                }
                .disabled(!song.hasSpan)
                .opacity(song.hasSpan ? 1 : 0.5)
                if let refused = model.refusedEdit, refused.songID == song.id || refused.conflicts.contains(song.id) {
                    Label(refused.message, systemImage: "exclamationmark.triangle.fill")
                        .font(TrigType.secondary)
                        .foregroundColor(StateColor.caution)
                        .padding(.horizontal, 4)
                } else {
                    Footnote("Capture takes the live timecode\(model.playhead.map { ", now \($0)" } ?? "").")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                GroupHeader("MIDI triggers")
                GroupedBox {
                    noteRow(.start, help: "Its Note On makes the Song Enter: sends its Start Actions and makes it current, even with no timecode")
                    RowDivider()
                    noteRow(.stop, help: "Its Note On Ends the Song if it is current. With no span and no Start Note, it sends the Stop Actions every time")
                }
                Footnote("Channel 1 to 16 and note 0 to 127. Leave both empty for none.")
            }
        }
        .disabled(model.isShowLocked)
        .sheet(item: $learningNote) { field in
            LearnSheet(title: "Learn the \(field.rawValue)",
                       hint: "Send a Note On from any of these MIDI inputs. Its channel and note become the \(field.rawValue).",
                       listensForOSC: false) { midi, _ in
                guard let trigger = midi.flatMap(Learn.noteTrigger(from:)), var edited = model.song(song.id) else { return false }
                edited[keyPath: field.keyPath] = trigger
                model.update(edited)
                return true
            }
            .environmentObject(model)
        }
    }

    private func spanRow(_ label: String, value: Timecode, keyPath: WritableKeyPath<Song, Timecode>,
                         capture: @escaping () -> Void) -> some View {
        FormRow(label: label) {
            TimecodeField(label, value: value) { timecode in
                var edited = song
                edited[keyPath: keyPath] = timecode
                return model.update(edited)
            }
            Button("Capture", action: capture)
                .capsuleButton()
                .disabled(model.playhead == nil)
                .help("Set the \(label.lowercased()) to the live Playhead")
        }
        .frame(minHeight: 60)
    }

    private func noteRow(_ field: NoteField, help: String) -> some View {
        FormRow(label: field.rawValue) {
            NoteTriggerField(label: field.rawValue, value: song[keyPath: field.keyPath]) { note in
                var edited = song
                edited[keyPath: field.keyPath] = note
                return model.update(edited)
            }
            .help(help)
            Button("Learn") { learningNote = field }
                .capsuleButton()
                .help("Set the \(field.rawValue) from the next Note On")
                .accessibilityLabel("Learn \(field.rawValue)")
        }
    }
}

// MARK: - Actions

struct SongActionsEditor: View {
    @EnvironmentObject private var model: ShowModel
    let song: Song
    @State private var presetList: ShowModel.ActionList?
    @State private var learnList: ShowModel.ActionList?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                GroupHeader("When")
                GroupedBox {
                    if song.hasSpan {
                        FormRow(label: "Timecode enters the span") {
                            Text(song.start.description).font(.system(size: 20, weight: .semibold).monospacedDigit())
                        }
                    }
                    if song.hasSpan && song.startNote != nil { RowDivider() }
                    if let note = song.startNote {
                        FormRow(label: "Start Note arrives") {
                            Text(note.spoken.prefix(1).uppercased() + note.spoken.dropFirst()).foregroundColor(.secondary)
                        }
                    }
                    if !song.hasSpan && song.startNote == nil {
                        FormRow(label: "Only Fire or the Stop Note") { EmptyView() }
                    }
                }
            }
            actionGroup(.start, title: "Send", empty: "No Actions yet. Add one to send when this Song starts.")
            VStack(alignment: .leading, spacing: 8) {
                GroupHeader("When it ends")
                GroupedBox {
                    FormRow(label: song.hasSpan ? "Timecode passes \(song.end) or stops" : "The Stop Note arrives") {
                        if song.stopActions.isEmpty {
                            Text("No Stop Actions").foregroundColor(.secondary)
                        }
                        addMenu(.stop, label: "Add")
                    }
                    ForEach(song.stopActions) { action in
                        RowDivider()
                        ActionRow(songID: song.id, list: .stop, action: action)
                    }
                }
                Footnote("Usually empty; for DJ pull-ups that must tell other gear the set has stopped.")
            }
            if model.set.destinations.isEmpty {
                Footnote("Add a Destination first, in Destinations.")
            }
        }
        .sheet(item: $presetList) { list in
            PresetSheet { model.addAction($0, to: song.id, list: list) }
        }
        .sheet(item: $learnList) { list in
            LearnSheet(title: "Learn an Action",
                       hint: "Send a Note On, an MSC GO, STOP or RESUME, or an OSC message to this Mac. The first one becomes a new Action; then pick its Destination.",
                       listensForOSC: true) { midi, packet in
                guard let message = midi.flatMap(Learn.actionMessage(from:)) ?? packet.flatMap(Learn.actionMessage(fromOSC:))
                else { return false }
                model.addAction(message, to: song.id, list: list)
                return true
            }
            .environmentObject(model)
        }
    }

    private func actionGroup(_ list: ShowModel.ActionList, title: String, empty: String) -> some View {
        let actions = song[keyPath: list.keyPath]
        return VStack(alignment: .leading, spacing: 8) {
            GroupHeader(title: title) { addMenu(list, label: "Add Action") }
            if actions.isEmpty {
                GroupedBox { FormRow(label: empty) { EmptyView() }.foregroundColor(.secondary) }
            } else {
                GroupedBox {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { RowDivider() }
                        ActionRow(songID: song.id, list: list, action: action)
                    }
                }
                Footnote("Sent in this order. Drag the handle to reorder. Arguments: 1 is an int, 0.5 a float, text a string; \"quote\" strings with spaces.")
            }
        }
    }

    private func addMenu(_ list: ShowModel.ActionList, label: String) -> some View {
        Menu {
            ForEach(ShowModel.NewActionKind.allCases, id: \.self) { kind in
                Button(kind.label) { model.addAction(kind, to: song.id, list: list) }
            }
            Divider()
            Button("From Resolume or grandMA3 Preset…") { presetList = list }
            Button("Learn from MIDI or OSC…") { learnList = list }
        } label: {
            Label(label, systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(TrigType.body)
        .disabled(model.set.destinations.isEmpty || model.isShowLocked)
    }
}

extension ShowModel.ActionList: Identifiable {
    var id: Self { self }
}

/// One Action: its Destination and kind, its fields, its last send and Test.
struct ActionRow: View {
    @EnvironmentObject private var model: ShowModel
    let songID: SongID
    let list: ShowModel.ActionList
    let action: Action

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
                .help("Drag to reorder")
                .accessibilityHidden(true)
                .draggable(String(action.id.rawValue))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Picker("Destination", selection: Binding(
                        get: { action.destinationID },
                        set: { id in
                            var edited = action
                            edited.destinationID = id
                            model.update(edited, in: songID)
                        }
                    )) {
                        ForEach(model.set.destinations) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .menuStyle(.borderlessButton)
                    .font(TrigType.rowTitle)
                    .fixedSize()
                    Text(kind).font(TrigType.secondary).foregroundColor(.secondary)
                    if let problem = transportProblem {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(StateColor.caution)
                            .help(problem)
                            .accessibilityLabel(problem)
                    }
                }
                HStack(spacing: 6) {
                    switch action.message {
                    case .osc(let message): OSCActionFields(message: message) { update(.osc($0)) }
                    case .midiNote(let note): MIDINoteFields(note: note) { update(.midiNote($0)) }
                    case .msc(let command): MSCFields(command: command) { update(.msc($0)) }
                    case .dmxPulse(let pulse): DMXPulseFields(pulse: pulse) { update(.dmxPulse($0)) }
                    }
                }
                .font(.system(size: 15))
                .lineLimit(1)
            }
            .disabled(model.isShowLocked)
            Spacer(minLength: 8)
            if let result = model.sendResults[action.id] {
                SendStatusBlock(result: result)
            }
            Button(model.sendResults[action.id]?.ok == false ? "Retry" : "Test") { model.test(action, in: songID) }
                .capsuleButton()
                .help("Send just this Action now, even if disarmed")
            Button(role: .destructive) {
                model.deleteAction(action.id, in: songID)
            } label: {
                Label("Delete Action", systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(model.isShowLocked)
            .help("Delete this Action")
        }
        .padding(.vertical, 10)
        .frame(minHeight: 68)
        .dropDestination(for: String.self) { items, _ in
            let actions = model.song(songID)?[keyPath: list.keyPath] ?? []
            guard !model.isShowLocked, let raw = items.first.flatMap(UInt64.init),
                  let from = actions.firstIndex(where: { $0.id.rawValue == raw }),
                  let to = actions.firstIndex(where: { $0.id == action.id }), from != to else { return false }
            // The dropped Action takes this row's place.
            model.moveActions(in: songID, list: list, from: [from], to: from < to ? to + 1 : to)
            return true
        }
    }

    private var kind: String {
        switch action.message {
        case .osc: return "OSC"
        case .midiNote: return "MIDI Note"
        case .msc: return "MIDI Show Control"
        case .dmxPulse: return "\(model.set.destination(action.destinationID)?.dmxOutput?.name ?? "DMX") pulse"
        }
    }

    /// Why this Action's Destination can't carry it, if it can't.
    private var transportProblem: String? {
        guard let destination = model.set.destination(action.destinationID) else { return nil }
        switch action.message {
        case .osc:
            return nil
        case .midiNote, .msc:
            return destination.midiOutput == nil ? "This Destination has no MIDI output; set one in Destinations" : nil
        case .dmxPulse(let pulse):
            guard let output = destination.dmxOutput else {
                return "This Destination has no Art-Net or sACN output; set one in Destinations"
            }
            return output.universeRange.contains(pulse.universe)
                ? nil : "Universe \(pulse.universe) is outside \(output.name)'s range \(output.universeRange.lowerBound) to \(output.universeRange.upperBound)"
        }
    }

    private func update(_ message: Action.Message) {
        var edited = action
        edited.message = message
        model.update(edited, in: songID)
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


// MARK: - Triggers

/// A MIDI channel (1...16) and note number (0...127), or none when both are empty.
struct NoteTriggerField: View {
    let label: String
    let value: NoteTrigger?
    let onCommit: (NoteTrigger?) -> Bool
    @State private var channel: String
    @State private var note: String
    @State private var refused = false

    init(label: String, value: NoteTrigger?, onCommit: @escaping (NoteTrigger?) -> Bool) {
        self.label = label
        self.value = value
        self.onCommit = onCommit
        _channel = State(initialValue: value.map { String($0.channel + 1) } ?? "")
        _note = State(initialValue: value.map { String($0.note) } ?? "")
    }

    /// nil: the text is not a valid trigger. .some(nil): both fields empty.
    private var parsed: NoteTrigger?? {
        if channel.isEmpty && note.isEmpty { return .some(nil) }
        guard let ch = UInt8(channel), (1...16).contains(ch), let n = UInt8(note), n <= 127 else { return nil }
        return .some(NoteTrigger(channel: ch - 1, note: n))
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Channel").foregroundColor(.secondary)
            TextField("Ch", text: binding(isChannel: true), prompt: Text("ch"))
                .frame(width: 60)
                .accessibilityLabel("\(label) MIDI channel, 1 to 16")
            Text("Note").foregroundColor(.secondary)
            TextField("Note", text: binding(isChannel: false), prompt: Text("note"))
                .frame(width: 70)
                .accessibilityLabel("\(label) note number, 0 to 127")
            Text(value.map { MIDINote(channel: $0.channel, note: $0.note).noteName } ?? "None")
                .foregroundColor(.secondary)
                .frame(width: 48, alignment: .leading)
        }
        .labelsHidden()
        .textFieldStyle(TrigFieldStyle())
        .font(TrigType.body.monospacedDigit())
        .foregroundColor(parsed == nil || refused ? StateColor.alert : .primary)
        .onChange(of: value) { newValue in
            channel = newValue.map { String($0.channel + 1) } ?? ""
            note = newValue.map { String($0.note) } ?? ""
            refused = false
        }
    }

    private func binding(isChannel: Bool) -> Binding<String> {
        Binding(
            get: { isChannel ? channel : note },
            set: { text in
                if isChannel { channel = text } else { note = text }
                if let trigger = parsed, trigger != value { refused = !onCommit(trigger) }
            }
        )
    }
}

// MARK: - Action fields

/// Picks a Resolume or grandMA3 preset and its numbers; adds an ordinary, editable Action.
struct PresetSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case resolumeColumn = "Resolume: launch column"
        case resolumeClip = "Resolume: launch clip"
        case resolumeClearLayer = "Resolume: clear layer"
        case resolumeClearAll = "Resolume: clear composition"
        case resolumeNextColumn = "Resolume: next column"
        case resolumePreviousColumn = "Resolume: previous column"
        case resolumeResync = "Resolume: tempo resync"
        case ma3Executor = "grandMA3: Go+ executor (OSC)"
        case ma3Command = "grandMA3: command (OSC)"
        case ma3Cue = "grandMA3: GO cue in list (MSC)"
        var id: Self { self }
    }

    let onAdd: (ActionPreset) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.resolumeColumn
    @State private var first = 1
    @State private var second = 1
    @State private var text = ""

    private var preset: ActionPreset {
        switch kind {
        case .resolumeColumn: return .resolumeLaunchColumn(column: first)
        case .resolumeClip: return .resolumeLaunchClip(layer: first, column: second)
        case .resolumeClearLayer: return .resolumeClearLayer(layer: first)
        case .resolumeClearAll: return .resolumeClearComposition
        case .resolumeNextColumn: return .resolumeNextColumn
        case .resolumePreviousColumn: return .resolumePreviousColumn
        case .resolumeResync: return .resolumeTempoResync
        case .ma3Executor: return .ma3GoExecutor(page: first, executor: second)
        case .ma3Command: return .ma3Command(text)
        case .ma3Cue: return .ma3GoCue(cue: text, list: first == 0 ? "" : String(first))
        }
    }

    /// Labels of the number fields this preset needs.
    private var numberLabels: [String] {
        switch kind {
        case .resolumeColumn: return ["Column"]
        case .resolumeClip: return ["Layer", "Column"]
        case .resolumeClearLayer: return ["Layer"]
        case .ma3Executor: return ["Page", "Executor"]
        case .ma3Cue: return ["Cue list (0 = selected executor)"]
        case .resolumeClearAll, .resolumeNextColumn, .resolumePreviousColumn, .resolumeResync, .ma3Command: return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Action from preset").font(.headline)
            Form {
                Picker("Preset", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                ForEach(Array(numberLabels.enumerated()), id: \.offset) { index, label in
                    TextField(label, value: index == 0 ? $first : $second, format: .number)
                }
                if kind == .ma3Command {
                    TextField("Command", text: $text, prompt: Text("Go+ Exec 1.201"))
                }
                if kind == .ma3Cue {
                    TextField("Cue", text: $text, prompt: Text("5 or 12.5"))
                }
            }
            Text("Sends \(ShowModel.describe(preset.message)). The Action stays editable after adding.")
                .font(.caption)
                .foregroundColor(.secondary)
            if kind == .ma3Executor || kind == .ma3Command {
                Text("On the console, turn on Receive Command for the OSC line. If it has a prefix, edit the address to start with it, like /gma3/cmd.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(preset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 440)
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
        .font(TrigType.code)
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
        .font(TrigType.code)
        .foregroundColor(OSCArgument.parseList(argumentsText) == nil ? .red : .primary)
        .frame(minWidth: 120, idealWidth: 220, maxWidth: 260)
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
        Text(note.noteName).foregroundColor(.secondary).frame(width: 48, alignment: .leading)
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
        .frame(width: 120)
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
        .font(.system(size: 15).monospacedDigit())
        .frame(width: 76)
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
        .font(.system(size: 15).monospacedDigit())
        .frame(width: 76)
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
        .font(.system(size: 15).monospacedDigit())
        .foregroundColor(parsed == nil ? .red : .primary)
        .frame(width: width + 24)
        .onChange(of: value) { text = String($0) }
    }
}
