// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import TrigITEngine
import TrigITProtocols
import UniformTypeIdentifiers

/// Asks before a delete. Cancel comes first, so Return and Esc never delete.
@MainActor
func confirmDelete(_ message: String, detail: String) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = message
    alert.informativeText = detail
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Delete").hasDestructiveAction = true
    return alert.runModal() == .alertSecondButtonReturn
}

/// The Song list on the left, the selected Song's Timing or Actions on the right.
struct SetEditorView: View {
    @EnvironmentObject private var model: ShowModel
    @State private var selection: SongID?
    @State private var importReport: ImportSummary?
    /// The Song whose name field should take focus, with its text selected.
    @State private var renaming: SongID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.set.songs) { song in
                        SongListRow(song: song).tag(song.id)
                    }
                }
                .listStyle(.inset)
                // Double-click or Return on a row renames it.
                .contextMenu(forSelectionType: SongID.self) { ids in
                    if let id = ids.first, ids.count == 1 {
                        Button("Rename") { rename(id) }.disabled(model.isShowLocked)
                    }
                    if !ids.isEmpty {
                        Button(ids.count > 1 ? "Delete Songs" : "Delete Song") { delete(Array(ids)) }
                            .disabled(model.isShowLocked)
                    }
                } primaryAction: { ids in
                    if let id = ids.first, ids.count == 1 { rename(id) }
                }
                .onDeleteCommand { if let selection, !model.isShowLocked { delete([selection]) } }
                RowDivider()
                HStack {
                    Button { if let id = model.addSong() { rename(id) } } label: {
                        Label("Song", systemImage: "plus")
                    }
                    Button("Import CSV…") { importCSV() }
                    Spacer()
                    Button { if let selection { delete([selection]) } } label: {
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
                    SongDetail(song: song, renaming: $renaming).id(song.id)
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

    private func rename(_ id: SongID) {
        guard !model.isShowLocked else { return }
        selection = id
        renaming = id
    }

    /// Asks first, naming the Songs and the Actions that go with them.
    private func delete(_ ids: [SongID]) {
        let songs = ids.compactMap(model.song)
        guard !songs.isEmpty else { return }
        let starts = songs.map(\.startActions.count).reduce(0, +)
        let stops = songs.map(\.stopActions.count).reduce(0, +)
        func count(_ n: Int, _ kind: String) -> String? { n == 0 ? nil : "\(n) \(kind) Action\(n == 1 ? "" : "s")" }
        let actions = [count(starts, "Start"), count(stops, "Stop")].compactMap { $0 }.joined(separator: " and ")
        let one = songs.count == 1
        guard confirmDelete(
            one ? "Delete \u{201C}\(songs[0].name)\u{201D}?" : "Delete \(songs.count) Songs?",
            detail: actions.isEmpty
                ? (one ? "It has no Actions." : "They have no Actions.")
                : "\(one ? "Its" : "Their") \(actions) will be deleted too."
        ) else { return }
        for song in songs {
            model.deleteSong(song.id)
            if selection == song.id { selection = nil }
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a CSV file with the columns name, start, end (hh:mm:ss:ff), and optionally destination, kind, address, args, when."
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
                Text(actionCounts).font(TrigType.secondary).foregroundColor(.secondary).lineLimit(1)
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

    /// "2 Start Actions, 1 Stop Action", "2 Start Actions" or "No Actions".
    private var actionCounts: String {
        func count(_ n: Int, _ kind: String) -> String? { n == 0 ? nil : "\(n) \(kind) Action\(n == 1 ? "" : "s")" }
        let parts = [count(song.startActions.count, "Start"), count(song.stopActions.count, "Stop")].compactMap { $0 }
        return parts.isEmpty ? "No Actions" : parts.joined(separator: ", ")
    }

    private var problem: String? {
        if song.hasSpan && song.end < song.start { return "End is before start: this Song never fires" }
        if let refused = model.refusedEdit, refused.songID == song.id || refused.conflicts.contains(song.id) {
            return refused.message
        }
        let clashes = model.set.noteClashMessages(for: song.id)
        return clashes.isEmpty ? nil : clashes.joined(separator: "\n")
    }
}

extension ShowSet {
    /// Warnings about a Song's Note Clashes: those of its Start Note field,
    /// its Stop Note field, or both (nil).
    func noteClashMessages(for songID: SongID, field: SongSectionsEditor.NoteField? = nil) -> [String] {
        func names(_ ids: [SongID]) -> String {
            ids.filter { $0 != songID }.compactMap { id in songs.first { $0.id == id } }
                .map { "\"\($0.name)\"" }.joined(separator: ", ")
        }
        return noteClashes.filter { $0.songs.contains(songID) }.compactMap { clash in
            switch clash.kind {
            case .startNote where field != .stop:
                return "Start Note \(clash.note.spoken) is also the Start Note of \(names(clash.songs))"
            case .stopNote where field != .start:
                return "Stop Note \(clash.note.spoken) is also the Stop Note of \(names(clash.songs))"
            case .startIsStop:
                return "Start Note and Stop Note are both \(clash.note.spoken): the Song Ends and Enters again"
            default:
                return nil
            }
        }
    }
}

extension NoteTrigger {
    /// "channel 1, C3"
    var spoken: String {
        "channel \(channel + 1), \(MIDINote(channel: channel, note: note).noteName)"
    }
}

/// The selected Song on one page: its name and span switch, then a Start
/// section and an End section that mirror each other.
struct SongDetail: View {
    @EnvironmentObject private var model: ShowModel
    let song: Song
    @Binding var renaming: SongID?
    @FocusState private var nameFocused: Bool
    @State private var nameHovered = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    nameField
                    spanSwitch
                }
                SongSectionsEditor(song: song)
            }
            .padding(EdgeInsets(top: 16, leading: 32, bottom: 28, trailing: 32))
        }
        .onAppear(perform: takeRenameRequest)
        .onChange(of: renaming) { _ in takeRenameRequest() }
    }

    private var nameField: some View {
        HStack(spacing: 12) {
            TextField("Song name", text: Binding(get: { song.name }, set: { name in
                var edited = song
                edited.name = name
                model.update(edited)
            }))
            .textFieldStyle(.plain)
            .font(TrigType.pageTitle)
            .focused($nameFocused)
            .onSubmit { nameFocused = false }
            // Looks like a heading until hovered or focused, then like a field.
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(nameFocused || (nameHovered && !model.isShowLocked) ? Surface.selection : .clear)
            )
            .padding(.horizontal, -6)
            .onHover { nameHovered = $0 }
            .disabled(model.isShowLocked)
            .help(model.isShowLocked ? "Unlock the Show to rename this Song" : "Song name: click to rename")
            if !model.isShowLocked {
                Image(systemName: "pencil")
                    .foregroundColor(.secondary)
                    .opacity(nameHovered || nameFocused ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Turns the start time and the end time on together.
    private var spanSwitch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Timecode span", isOn: Binding(get: { song.hasSpan }, set: { hasSpan in
                var edited = song
                edited.hasSpan = hasSpan
                model.update(edited)
            }))
            .toggleStyle(.switch)
            .font(TrigType.label)
            .fixedSize()
            .disabled(model.isShowLocked)
            .help("Off: only the notes trigger this Song; its start and end times are kept but ignored")
            if let refused = model.refusedEdit, refused.songID == song.id || refused.conflicts.contains(song.id) {
                Label(refused.message, systemImage: "exclamationmark.triangle.fill")
                    .font(TrigType.secondary)
                    .foregroundColor(StateColor.caution)
            } else if song.hasSpan {
                Footnote("Capture takes the live timecode\(model.playhead.map { ", now \($0)" } ?? "").")
                    .padding(.horizontal, -4)
            }
        }
    }

    /// Focusing an AppKit text field selects all its text, so typing replaces "Song N".
    private func takeRenameRequest() {
        guard renaming == song.id else { return }
        renaming = nil
        DispatchQueue.main.async { nameFocused = true }
    }
}

// MARK: - Start and End

/// The Start section (start time, Start Note, Send Start, Start Actions) and
/// the End section below it. Told apart by symbol and position, not colour.
struct SongSectionsEditor: View {
    @EnvironmentObject private var model: ShowModel
    let song: Song
    @State private var learningNote: NoteField?
    @State private var presetList: ShowModel.ActionList?
    @State private var learnList: ShowModel.ActionList?

    enum NoteField: String, Identifiable {
        case start = "Start Note", stop = "Stop Note"
        var id: Self { self }
        var keyPath: WritableKeyPath<Song, NoteTrigger?> { self == .start ? \.startNote : \.stopNote }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            startSection
            endSection
            if model.set.destinations.isEmpty {
                Footnote("Add a Destination first, in Destinations.")
            }
        }
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

    // MARK: Sections

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Start", symbol: "play.fill") {
                // Manual sending works under Show Lock and while disarmed.
                Button { model.fire(song.id) } label: { Label("Send Start", systemImage: "play.fill") }
                    .capsuleButton()
                    .help("Send this Song's Start Actions now, even if disarmed")
            }
            GroupedBox {
                timeRow(.start)
                RowDivider()
                noteRow(.start, help: "Its Note On makes the Song Enter: sends its Start Actions and makes it current, even with no timecode")
            }
            actionList(.start, title: "Start Actions")
        }
    }

    private var endSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("End", symbol: "stop.fill") {
                Button { model.fireStop(song.id) } label: { Label("Send Stop", systemImage: "stop.fill") }
                    .capsuleButton()
                    .disabled(song.stopActions.isEmpty)
                    .help("Send this Song's Stop Actions now, even if disarmed")
            }
            if song.stopActions.isEmpty {
                // One collapsed line while there is nothing to send; stacked if it doesn't fit.
                GroupedBox {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            timeControls(.end)
                            noteControls(.stop)
                            Spacer(minLength: 12)
                            Text("No Stop Actions").font(TrigType.body).foregroundColor(.secondary)
                            addMenu(.stop, label: "Add")
                        }
                        .frame(minHeight: 60)
                        VStack(spacing: 0) {
                            timeRow(.end)
                            RowDivider()
                            noteRow(.stop, help: stopNoteHelp, warns: false)
                            RowDivider()
                            FormRow(label: "No Stop Actions") { addMenu(.stop, label: "Add") }
                                .foregroundColor(.secondary)
                        }
                    }
                }
                noteClashWarning(.stop)
                Footnote("Stop Actions are usually empty. They are sent when the Playhead passes the end time or the Stop Note arrives, never on a timecode Stop.")
            } else {
                GroupedBox {
                    timeRow(.end)
                    RowDivider()
                    noteRow(.stop, help: stopNoteHelp)
                }
                actionList(.stop, title: "Stop Actions")
            }
        }
    }

    private let stopNoteHelp = "Its Note On Ends the Song if it is current. With no span and no Start Note, it sends the Stop Actions every time"

    private func sectionHeader<Trailing: View>(_ title: String, symbol: String,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: symbol).font(TrigType.sectionTitle)
            Spacer()
            trailing()
        }
    }

    // MARK: Time and note

    private enum TimeField {
        case start, end
        var label: String { self == .start ? "Start time" : "End time" }
        var keyPath: WritableKeyPath<Song, Timecode> { self == .start ? \.start : \.end }
    }

    private func timeRow(_ field: TimeField) -> some View {
        FormRow(label: field.label) { timeControls(field, labelled: false) }
            .frame(minHeight: 60)
    }

    /// The time field and Capture, with a label when it sits on the collapsed line.
    @ViewBuilder
    private func timeControls(_ field: TimeField, labelled: Bool = true) -> some View {
        HStack(spacing: 10) {
            if labelled { Text(field.label).font(TrigType.label) }
            TimecodeField(field.label, value: song[keyPath: field.keyPath]) { timecode in
                var edited = song
                edited[keyPath: field.keyPath] = timecode
                return model.update(edited)
            }
            Button("Capture") { field == .start ? model.captureStart(for: song.id) : model.captureEnd(for: song.id) }
                .capsuleButton()
                .disabled(model.playhead == nil)
                .help("Set the \(field.label.lowercased()) to the live Playhead")
        }
        .disabled(!song.hasSpan || model.isShowLocked)
        .opacity(song.hasSpan ? 1 : 0.5)
    }

    private func noteRow(_ field: NoteField, help: String, warns: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FormRow(label: field.rawValue) { noteControls(field, labelled: false) }
                .help(help)
            if warns { noteClashWarning(field) }
        }
    }

    /// Warns, but allows, a note that clashes with another Song's or its own.
    @ViewBuilder
    private func noteClashWarning(_ field: NoteField) -> some View {
        let messages = model.set.noteClashMessages(for: song.id, field: field)
        if !messages.isEmpty {
            Label(messages.joined(separator: "\n"), systemImage: "exclamationmark.triangle.fill")
                .font(TrigType.secondary)
                .foregroundColor(StateColor.caution)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func noteControls(_ field: NoteField, labelled: Bool = true) -> some View {
        HStack(spacing: 10) {
            if labelled { Text(field.rawValue).font(TrigType.label) }
            NoteTriggerField(label: field.rawValue, value: song[keyPath: field.keyPath]) { note in
                var edited = song
                edited[keyPath: field.keyPath] = note
                return model.update(edited)
            }
            Button("Learn") { learningNote = field }
                .capsuleButton()
                .help("Set the \(field.rawValue) from the next Note On")
                .accessibilityLabel("Learn \(field.rawValue)")
        }
        .disabled(model.isShowLocked)
    }

    // MARK: Actions

    private func actionList(_ list: ShowModel.ActionList, title: String) -> some View {
        let actions = song[keyPath: list.keyPath]
        return VStack(alignment: .leading, spacing: 8) {
            GroupHeader(title: title) { addMenu(list, label: "Add Action") }
            if actions.isEmpty {
                GroupedBox {
                    FormRow(label: "No \(title) yet. Add one to send when this Song starts.") { EmptyView() }
                        .foregroundColor(.secondary)
                }
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
                    .disabled(!model.set.destinations.contains(where: kind.canUse))
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
                        // Only Destinations that can carry it, plus its own so the choice stays visible.
                        ForEach(model.set.destinations.filter { $0.canCarry(action.message) || $0.id == action.destinationID }) {
                            Text($0.name).tag($0.id)
                        }
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
        case .dmxPulse: return "\(model.set.destination(action.destinationID)?.activeDMXOutput?.name ?? "DMX") pulse"
        }
    }

    /// Why this Action's Destination can't carry it, if it can't.
    private var transportProblem: String? {
        guard let destination = model.set.destination(action.destinationID) else { return nil }
        guard destination.canCarry(action.message) else {
            return "\(action.message.transport.name) is off for this Destination; switch it on in Destinations"
        }
        switch action.message {
        case .osc:
            return nil
        case .midiNote, .msc:
            return destination.midiOutput == nil ? "This Destination has no MIDI output; set one in Destinations" : nil
        case .dmxPulse(let pulse):
            guard let output = destination.activeDMXOutput else { return nil }
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from \(summary.fileName)").font(TrigType.sectionTitle)
            if let report = summary.report {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(StateColor.ok)
                    Text("Added \(report.imported.count) Song\(report.imported.count == 1 ? "" : "s").")
                }
                .font(TrigType.body)
                if report.problems.isEmpty {
                    Text("Every row was imported.").font(.system(size: 16)).foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        GroupHeader("Skipped \(report.problems.count) row\(report.problems.count == 1 ? "" : "s")")
                        ScrollView {
                            GroupedBox {
                                ForEach(Array(report.problems.enumerated()), id: \.offset) { index, problem in
                                    if index > 0 { RowDivider() }
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(StateColor.caution)
                                        Text("Line \(problem.line)").font(TrigType.rowTitle.monospacedDigit()).frame(width: 70, alignment: .leading)
                                        Text(problem.reason.description).font(TrigType.body)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 12)
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                    }
                }
            } else {
                Label("The file could not be read as text.", systemImage: "xmark.circle.fill")
                    .font(TrigType.body).foregroundStyle(StateColor.alert, .primary)
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction).prominentCapsuleButton()
            }
        }
        .padding(26)
        .frame(width: 560)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Action from Preset").font(TrigType.sectionTitle)
            GroupedBox {
                FormRow(label: "Preset") {
                    Picker("Preset", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 300)
                }
                ForEach(Array(numberLabels.enumerated()), id: \.offset) { index, label in
                    RowDivider()
                    FormRow(label: label) {
                        TextField(label, value: index == 0 ? $first : $second, format: .number)
                            .labelsHidden()
                            .font(TrigType.body.monospacedDigit())
                            .frame(width: 100)
                    }
                }
                if kind == .ma3Command || kind == .ma3Cue {
                    RowDivider()
                    FormRow(label: kind == .ma3Command ? "Command" : "Cue") {
                        TextField(kind == .ma3Command ? "Command" : "Cue", text: $text,
                                  prompt: Text(kind == .ma3Command ? "Go+ Exec 1.201" : "5 or 12.5"))
                            .labelsHidden()
                            .font(TrigType.code)
                            .frame(width: 220)
                    }
                }
            }
            Footnote("Sends \(ShowModel.describe(preset.message)). The Action stays editable after adding.")
            if kind == .ma3Executor || kind == .ma3Command {
                Footnote("On the console, turn on Receive Command for the OSC line. If it has a prefix, edit the address to start with it, like /gma3/cmd.")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).capsuleButton()
                Button("Add") {
                    onAdd(preset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .prominentCapsuleButton()
            }
        }
        .padding(26)
        .frame(width: 560)
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
