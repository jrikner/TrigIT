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
            if let alert = model.alert {
                TimecodeAlertBanner(text: ShowModel.alertText(alert))
            }
            HStack {
                SourceBadge()
                Spacer()
                Text(model.frameRate.map { "\($0.rawValue) fps" } ?? "-- fps")
                    .font(.system(.title3, design: .monospaced))
            }
            SourcePicker()
            SourceHealthView()

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

/// A flashing red banner saying exactly what is wrong with timecode. It goes
/// away by itself when the engine clears the alert.
struct TimecodeAlertBanner: View {
    let text: String
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red))
            .foregroundColor(.white)
            .opacity(dim ? 0.35 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Each chosen source, its health, and which one is live.
struct SourceHealthView: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(.primary)
            if model.backupSource != nil { row(.backup) }
        }
        .font(.callout)
    }

    private func row(_ role: SourceRole) -> some View {
        let healthy = model.healthySources.contains(role)
        let live = model.liveSource == role
        return HStack(spacing: 6) {
            Image(systemName: healthy ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundColor(healthy ? .green : .red)
            Text(role == .primary ? "Primary" : "Backup").fontWeight(live ? .bold : .regular)
            Text(model.sourceLabel(for: role)).foregroundColor(.secondary).lineLimit(1)
            Text(healthy ? "OK" : "lost").foregroundColor(healthy ? .secondary : .red)
            if live { Text("LIVE").font(.caption.weight(.bold)).foregroundColor(.green) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Which source is live and whether timecode is arriving from it.
struct SourceBadge: View {
    @EnvironmentObject private var model: ShowModel

    private var live: TimecodeSourceChoice {
        (model.liveSource == .backup ? model.backupSource : nil) ?? model.source
    }

    var body: some View {
        HStack(spacing: 8) {
            switch live {
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
        switch live {
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

/// The Primary Source and the optional Backup Source.
struct SourcePicker: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Primary Source", selection: Binding(
                get: { model.source },
                set: { model.selectSource($0) }
            )) {
                ForEach(options(current: model.source), id: \.self) { choice in
                    Text(model.sourceLabel(choice)).tag(choice)
                }
            }
            Picker("Backup Source", selection: Binding<TimecodeSourceChoice?>(
                get: { model.backupSource },
                set: { model.selectBackupSource($0) }
            )) {
                Text("None").tag(TimecodeSourceChoice?.none)
                // One input per kind: the Backup must be a different kind than the Primary.
                ForEach(options(current: model.backupSource).filter { $0.kind != model.source.kind }, id: \.self) { choice in
                    Text(model.sourceLabel(choice)).tag(Optional(choice))
                }
            }
            Picker("MIDI notes", selection: Binding(
                get: { model.noteSourceID },
                set: { model.selectNoteSource($0) }
            )) {
                Text("None").tag(Int32?.none)
                ForEach(noteOptions, id: \.self) { id in
                    Text(model.noteSourceLabel(id)).tag(Optional(id))
                }
            }
            .help("Where Start and Stop Notes come from. It may be the same port as MTC.")
        }
        .frame(maxWidth: 420)
    }

    /// Every MIDI source, plus the chosen one if it is unplugged.
    private var noteOptions: [Int32] {
        var ids = model.midiSources.map(\.uniqueID)
        if let current = model.noteSourceID, !ids.contains(current) { ids.append(current) }
        return ids
    }

    /// Every available source, plus `current` if its device is unplugged, so
    /// a missing device stays visible rather than silently switching.
    private func options(current: TimecodeSourceChoice?) -> [TimecodeSourceChoice] {
        var choices: [TimecodeSourceChoice] = [.simulator]
        for device in model.audioInputDevices {
            choices += (0..<device.channelCount).map { .ltc(deviceUID: device.uid, channel: $0) }
        }
        choices += model.midiSources.map { .mtc(sourceID: $0.uniqueID) }
        choices += model.networkInterfaces.map { .artNet(interface: $0.name) }
        choices.append(.artNet(interface: nil))
        if let current, !choices.contains(current) { choices.append(current) }
        return choices
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
        .disabled(model.source != .simulator && model.backupSource != .simulator)
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
