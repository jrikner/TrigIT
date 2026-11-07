import SwiftUI
import TrigITEngine
import TrigITProtocols

/// The Song list, with the selected Song's Start Actions below it.
struct SetEditorView: View {
    @EnvironmentObject private var model: ShowModel
    @State private var selection: SongID?

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.set.name).font(.headline)
                    Spacer()
                    Button("Add Song") { model.addSong() }
                    Button("Delete") {
                        if let selection { model.deleteSong(selection) }
                        selection = nil
                    }
                    .disabled(selection == nil)
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
                    StartActionsEditor(song: song)
                } else {
                    Text("Select a Song to edit its Start Actions")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(8)
            .frame(minHeight: 160)
        }
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
                    model.update(edited)
                }
                TimecodeField(value: song.end) { end in
                    var edited = song
                    edited.end = end
                    model.update(edited)
                }
            }
            HStack {
                Text(song.startActions.isEmpty ? "No Start Actions" : "\(song.startActions.count) Start Action(s)")
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
    }
}

// MARK: - Start Actions

struct StartActionsEditor: View {
    @EnvironmentObject private var model: ShowModel
    let song: Song

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Start Actions: \(song.name)").font(.headline)
                Spacer()
                Button("Add OSC Action") { model.addOSCAction(to: song.id) }
                    .disabled(model.set.destinations.isEmpty)
            }
            if model.set.destinations.isEmpty {
                Text("Add a Destination first (Destinations tab).")
                    .foregroundColor(.secondary)
            }
            Text("Sent in this order when the Song is entered. Drag to reorder. Arguments: 1 is an int, 0.5 a float, text a string; \"quote\" strings with spaces.")
                .font(.caption)
                .foregroundColor(.secondary)
            List {
                ForEach(song.startActions) { action in
                    ActionRow(songID: song.id, action: action)
                }
                .onMove { offsets, destination in
                    model.moveActions(in: song.id, from: offsets, to: destination)
                }
            }
        }
    }
}

struct ActionRow: View {
    @EnvironmentObject private var model: ShowModel
    let songID: SongID
    let action: Action
    @State private var argumentsText: String

    init(songID: SongID, action: Action) {
        self.songID = songID
        self.action = action
        switch action.message {
        case .osc(let message):
            _argumentsText = State(initialValue: message.arguments.map(\.description).joined(separator: " "))
        }
    }

    var body: some View {
        switch action.message {
        case .osc(let message):
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

                TextField("/osc/address", text: Binding(
                    get: { message.address },
                    set: { address in
                        var edited = message
                        edited.address = address
                        update(edited)
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
                            update(edited)
                        }
                    }
                ))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(OSCArgument.parseList(argumentsText) == nil ? .red : .primary)
                .frame(width: 140)

                Button(role: .destructive) {
                    model.deleteAction(action.id, in: songID)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this Action")
            }
        }
    }

    private func update(_ message: OSCMessage) {
        var edited = action
        edited.message = .osc(message)
        model.update(edited, in: songID)
    }
}
