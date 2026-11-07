import SwiftUI
import TrigITEngine
import TrigITStorage

struct ContentView: View {
    @EnvironmentObject private var model: ShowModel
    @SceneStorage("showFireLog") private var showFireLog = true

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.documentProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .textSelection(.enabled)
                Divider()
            }
            HSplitView {
                TabView {
                    SetEditorView()
                        .tabItem { Text("Songs") }
                    DestinationsView()
                        .tabItem { Text("Destinations") }
                }
                .padding(8)
                .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity)
                .layoutPriority(1)

                VStack(spacing: 0) {
                    ShowScreenView()
                    Divider()
                    SimulatorControlsView()
                }
                .frame(minWidth: 400, idealWidth: 520, maxWidth: .infinity)
                .layoutPriority(1)

                if showFireLog {
                    FireLogView()
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 480)
                }
            }
        }
        .toolbar { ShowToolbar(showFireLog: $showFireLog) }
        .navigationTitle(model.windowTitle)
        .sheet(isPresented: $model.showingVersions) {
            PreviousVersionsView()
        }
    }
}

/// The Set's automatically kept earlier versions, newest first.
struct PreviousVersionsView: View {
    @EnvironmentObject private var model: ShowModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Previous versions of \(model.set.name)").font(.headline)
            Text("TrigIT keeps a version when a Set is opened and every two minutes while it is edited (the last 100). Restoring keeps the current Set as a version first, and can be undone.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let versions = model.previousVersions
            if versions.isEmpty {
                Text("No previous versions yet.").foregroundColor(.secondary)
            } else {
                List(versions, id: \.url) { version in
                    HStack {
                        Text(version.date.formatted(date: .abbreviated, time: .standard))
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Restore") {
                            model.restore(version)
                            dismiss()
                        }
                        .disabled(model.isShowLocked)
                    }
                }
                .frame(minHeight: 240)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}

// MARK: - Toolbar

/// Arm, Show Lock and the Fire log, in the window's native toolbar.
struct ShowToolbar: ToolbarContent {
    @EnvironmentObject private var model: ShowModel
    @Binding var showFireLog: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.setArmed(!model.isArmed)
            } label: {
                // Icon plus word, so the state never depends on color alone.
                Label(model.isArmed ? "Armed" : "Disarmed",
                      systemImage: model.isArmed ? "bolt.fill" : "bolt.slash")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                    .frame(minWidth: 110)
            }
            .buttonStyle(EngagedButtonStyle(isEngaged: model.isArmed, color: .red))
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help(model.isArmed ? "Disarm (⇧⌘A): timecode is still followed, nothing is sent"
                                : "Arm (⇧⌘A): Songs send their Actions when entered")
            .accessibilityValue(model.isArmed ? "Armed" : "Disarmed")

            Button {
                model.setShowLocked(!model.isShowLocked)
            } label: {
                Label("Show Lock", systemImage: model.isShowLocked ? "lock.fill" : "lock.open")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(EngagedButtonStyle(isEngaged: model.isShowLocked, color: .orange))
            .accessibilityAddTraits(model.isShowLocked ? .isSelected : [])
            .help("Make the Set read-only during the show. Arming and the Simulator still work.")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $showFireLog) {
                Label("Fire Log", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .help(showFireLog ? "Hide the Fire log" : "Show the Fire log")
        }
    }
}

/// A toolbar button that fills with `color` while its state is on. Toolbar
/// items ignore `.tint` and `.borderedProminent`, so this draws its own fill.
struct EngagedButtonStyle: ButtonStyle {
    let isEngaged: Bool
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // Black, not white: white on system red/orange is under 4.5:1 contrast.
            .foregroundColor(isEngaged ? .black : .primary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isEngaged ? color : Color.primary.opacity(0.08))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Show screen

struct ShowScreenView: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SourceBadge()
                Spacer()
                Text(model.frameRate.map { "\($0.rawValue) fps" } ?? "-- fps")
                    .font(.system(.title3, design: .monospaced))
            }
            SourcePicker()

            Text(model.playhead?.description ?? "--:--:--:--")
                .font(.system(size: 76, weight: .bold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text("Current Song").font(.caption).foregroundColor(.secondary)
                Text(model.currentSong?.name ?? "No Song")
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .foregroundColor(model.currentSong == nil ? .secondary : .primary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

// MARK: - Timecode Source

/// Which source is live and whether timecode is arriving from it.
struct SourceBadge: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.source {
            case .simulator:
                badge("SIMULATOR", color: .orange)
                Text(model.simulator.isPlaying ? "Playing" : "Stopped")
                    .foregroundColor(.secondary)
            case .ltc, .mtc, .artNet:
                badge(sourceKind, color: .green)
                if model.isReceiving {
                    Text("Receiving").foregroundColor(.secondary)
                } else {
                    Text("NO SIGNAL")
                        .font(.headline)
                        .foregroundColor(.red)
                }
            }
        }
    }

    private var sourceKind: String {
        switch model.source {
        case .mtc: return "MTC"
        case .artNet: return "ART-NET TC"
        default: return "LTC"
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.headline)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color))
            .foregroundColor(.black)
    }
}

struct SourcePicker: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        Picker("Timecode Source", selection: Binding(
            get: { model.source },
            set: { model.selectSource($0) }
        )) {
            Text("Simulator").tag(TimecodeSourceChoice.simulator)
            ForEach(model.audioInputDevices) { device in
                ForEach(0..<device.channelCount, id: \.self) { channel in
                    Text("LTC: \(device.name), channel \(channel + 1)")
                        .tag(TimecodeSourceChoice.ltc(deviceUID: device.uid, channel: channel))
                }
            }
            ForEach(model.midiSources) { source in
                Text("MTC: \(source.name)")
                    .tag(TimecodeSourceChoice.mtc(sourceID: source.uniqueID))
            }
            ForEach(model.networkInterfaces) { interface in
                Text("Art-Net Timecode: \(interface.label)")
                    .tag(TimecodeSourceChoice.artNet(interface: interface.name))
            }
            Text("Art-Net Timecode: any network interface")
                .tag(TimecodeSourceChoice.artNet(interface: nil))
            // Keep a chosen device that is unplugged visible rather than silently switching.
            if isMissing {
                Text(model.sourceLabel(model.source))
                    .tag(model.source)
            }
        }
        .frame(maxWidth: 420)
    }

    private var isMissing: Bool {
        switch model.source {
        case .simulator: return false
        case .ltc(let uid, _): return !model.audioInputDevices.contains { $0.uid == uid }
        case .mtc(let id): return !model.midiSources.contains { $0.uniqueID == id }
        case .artNet(let interface):
            guard let interface else { return false }
            return !model.networkInterfaces.contains { $0.name == interface }
        }
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
                TextField("Simulator timecode", text: $targetText, prompt: Text("hh:mm:ss:ff"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(target == nil ? .red : .primary)
                    .frame(minWidth: 100, idealWidth: 120, maxWidth: 120)
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
        // Disabled controls already dim themselves; extra opacity would dim them twice.
        .disabled(model.source != .simulator)
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

/// A text field for hh:mm:ss:ff. Valid text is offered to `onCommit` as you
/// type; text that isn't a timecode, or a value `onCommit` refuses, turns red.
/// When the value changes elsewhere (capture, undo) the text follows.
struct TimecodeField: View {
    /// Shared with the Song list's column header so the two line up.
    static let width: CGFloat = 110
    let label: String
    let value: Timecode
    let onCommit: (Timecode) -> Bool
    @State private var text: String
    @State private var refused = false

    init(_ label: String, value: Timecode, onCommit: @escaping (Timecode) -> Bool) {
        self.label = label
        self.value = value
        self.onCommit = onCommit
        _text = State(initialValue: value.description)
    }

    var body: some View {
        TextField(label, text: Binding(
            get: { text },
            set: { newText in
                text = newText
                if let timecode = Timecode(newText) {
                    refused = !onCommit(timecode)
                }
            }
        ), prompt: Text("hh:mm:ss:ff"))
        .labelsHidden()
        .font(.system(.body, design: .monospaced))
        .foregroundColor(Timecode(text) == nil || refused ? .red : .primary)
        .frame(width: TimecodeField.width)
        .onChange(of: value) { newValue in
            text = newValue.description
            refused = false
        }
    }
}
