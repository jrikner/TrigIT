import SwiftUI
import TrigITEngine

struct ContentView: View {
    var body: some View {
        HSplitView {
            SetEditorView()
                .frame(minWidth: 400, idealWidth: 440)
            VStack(spacing: 0) {
                ShowScreenView()
                Divider()
                SimulatorControlsView()
            }
            .frame(minWidth: 460)
        }
    }
}

// MARK: - Show screen

struct ShowScreenView: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("SIMULATOR")
                    .font(.headline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange))
                    .foregroundColor(.black)
                Text(model.simulator.isPlaying ? "Playing" : "Stopped")
                    .foregroundColor(.secondary)
                Spacer()
                Text(model.frameRate.map { "\($0.rawValue) fps" } ?? "-- fps")
                    .font(.system(.title3, design: .monospaced))
            }

            Text(model.playhead?.description ?? "--:--:--:--")
                .font(.system(size: 76, weight: .bold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text("Current Song").font(.caption).foregroundColor(.secondary)
                Text(model.currentSong?.name ?? "No Song")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(model.currentSong == nil ? .secondary : .primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Would fire (nothing is sent yet)").font(.caption).foregroundColor(.secondary)
                List(model.firings) { firing in
                    HStack {
                        Text(firing.timecode.description).font(.system(.body, design: .monospaced))
                        Text(firing.songName)
                    }
                }
                .frame(minHeight: 80)
            }
        }
        .padding(20)
    }
}

// MARK: - Simulator controls

struct SimulatorControlsView: View {
    @EnvironmentObject private var model: ShowModel
    @State private var targetText = "01:00:00:00"

    private var target: Timecode? { Timecode(targetText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Simulator").font(.headline)
            HStack {
                TextField("hh:mm:ss:ff", text: $targetText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(target == nil ? .red : .primary)
                    .frame(width: 120)
                Button("Play from") { if let target { model.play(from: target) } }
                    .disabled(target == nil)
                Button("Jump") { if let target { model.jump(to: target) } }
                    .disabled(target == nil)
                Spacer()
                Button("Play") { model.play() }
                    .disabled(model.simulator.isPlaying)
                Button("Stop") { model.stop() }
                    .disabled(!model.simulator.isPlaying)
            }
            Picker("Frame rate", selection: Binding(
                get: { model.simulator.frameRate },
                set: { model.setSimulatorFrameRate($0) }
            )) {
                ForEach(FrameRate.allCases, id: \.self) { rate in
                    Text(rate.rawValue).tag(rate)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(20)
    }
}

// MARK: - Set editor

struct SetEditorView: View {
    @EnvironmentObject private var model: ShowModel
    @State private var selection: SongID?

    var body: some View {
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
        .padding(16)
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
            if song.end < song.start {
                Text("End is before start: this Song never fires")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 2)
        .fontWeight(isCurrent ? .bold : .regular)
    }
}

/// A text field for hh:mm:ss:ff. Valid text updates the value as you type;
/// invalid text turns red and is not applied.
struct TimecodeField: View {
    let onCommit: (Timecode) -> Void
    @State private var text: String

    init(value: Timecode, onCommit: @escaping (Timecode) -> Void) {
        self.onCommit = onCommit
        _text = State(initialValue: value.description)
    }

    var body: some View {
        TextField("hh:mm:ss:ff", text: Binding(
            get: { text },
            set: { newText in
                text = newText
                if let timecode = Timecode(newText) { onCommit(timecode) }
            }
        ))
        .font(.system(.body, design: .monospaced))
        .foregroundColor(Timecode(text) == nil ? .red : .primary)
        .frame(width: 110)
    }
}
