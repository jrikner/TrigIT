import SwiftUI
import TrigITEngine

struct ContentView: View {
    @SceneStorage("showFireLog") private var showFireLog = true

    var body: some View {
        VStack(spacing: 0) {
            TopBarView(showFireLog: $showFireLog)
            Divider()
            HSplitView {
                TabView {
                    SetEditorView()
                        .tabItem { Text("Songs") }
                    DestinationsView()
                        .tabItem { Text("Destinations") }
                }
                .padding(8)
                .frame(minWidth: 460, idealWidth: 520)

                VStack(spacing: 0) {
                    ShowScreenView()
                    Divider()
                    SimulatorControlsView()
                }
                .frame(minWidth: 460)

                if showFireLog {
                    FireLogView()
                        .frame(minWidth: 260, idealWidth: 320)
                }
            }
        }
    }
}

// MARK: - Top bar

struct TopBarView: View {
    @EnvironmentObject private var model: ShowModel
    @Binding var showFireLog: Bool

    var body: some View {
        HStack {
            Button {
                model.setArmed(!model.isArmed)
            } label: {
                Text(model.isArmed ? "ARMED" : "DISARMED")
                    .font(.system(size: 18, weight: .heavy))
                    .frame(width: 160, height: 34)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.isArmed ? Color.red : Color.gray.opacity(0.35)))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help(model.isArmed ? "Click to disarm: timecode is still followed, nothing is sent"
                                : "Click to arm: Songs send their Actions when entered")
            Spacer()
            Toggle("Fire log", isOn: $showFireLog)
                .toggleStyle(.button)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
            Spacer(minLength: 0)
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

// MARK: - Fire log

struct FireLogView: View {
    @EnvironmentObject private var model: ShowModel

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fire log").font(.headline).padding([.top, .horizontal], 12)
            List(model.log) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(Self.timeFormat.string(from: entry.date))
                        Text(entry.timecode?.description ?? "")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    Text(entry.text)
                        .foregroundColor(entry.isError ? .red : .primary)
                        .textSelection(.enabled)
                }
            }
        }
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
