// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TrigITEngine
import TrigITStorage

struct ContentView: View {
    @EnvironmentObject private var model: ShowModel
    @State private var closedDocumentProblem: String?
    @State private var closedAlert: String?

    var body: some View {
        ZStack {
            if model.showingWelcome {
                WelcomeView()
            } else {
                main
            }
            if let name = model.openingSetName {
                OpeningView(setName: name)
            }
        }
        .preferredColorScheme(.dark)
        .controlSize(.large)
        .textFieldStyle(.roundedBorder)
        .sheet(isPresented: $model.showingVersions) { PreviousVersionsView() }
        .sheet(isPresented: $model.showingNewSetSetup) { NewSetSetupView() }
        .sheet(isPresented: $model.showingMA3Export) { MA3ExportView() }
    }

    private var main: some View {
        VStack(spacing: 0) {
            if let problem = visibleDocumentProblem {
                Banner(text: problem, pulses: false) { closedDocumentProblem = problem }
            }
            if let alert = visibleAlert {
                Banner(text: alert, pulses: true) { closedAlert = alert }
            }
            switch model.mode {
            case .show: ShowScreenView()
            case .edit: EditView(section: $model.section)
            }
            // In the layout, not a safe-area inset: the split view's scroll views
            // ignore that inset, so their last rows ended up under the panel.
            if model.source == .simulator || model.backupSource == .simulator {
                SimulatorPanel().padding(8)
            }
        }
        .background(closeWarningsShortcut)
        // Once a problem clears, the same problem coming back shows again.
        .onChange(of: model.alertLines.isEmpty) { if $0 { closedAlert = nil } }
        .onChange(of: model.documentProblem == nil) { if $0 { closedDocumentProblem = nil } }
        .toolbar { toolbar }
        .onAppear { if model.isShowLocked { model.setMode(.show) } }
        .navigationTitle(model.mode == .show ? model.setTitle : model.section.rawValue)
        .navigationSubtitle(model.mode == .show ? "" : model.setTitle)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // Show Lock keeps TrigIT in Show mode: Edit is off until the lock is off.
            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text("Show").tag(AppMode.show)
                Text("Edit").tag(AppMode.edit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(model.isShowLocked ? "Turn off Show Lock to edit" : "Show (⌘1) or Edit (⌘2)")
        }
        if model.mode == .edit && model.section == .fireLog {
            ToolbarItem(placement: .primaryAction) {
                Button("Export…") { model.exportLog() }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.mode == .show {
                ShowLockButton()
            } else if model.section != .fireLog {
                SourceStatusLabel()
            }
            ArmButton()
        }
        .withoutToolbarGlass()
    }

    // A closed banner stays hidden until its text changes, so a new problem shows again.
    private var visibleDocumentProblem: String? {
        model.documentProblem.flatMap { $0 == closedDocumentProblem ? nil : $0 }
    }

    private var visibleAlert: String? {
        let text = model.alertLines.joined(separator: "\n")
        return text.isEmpty || text == closedAlert ? nil : text
    }

    /// Esc closes the warning banners (⌘1 and ⌘2 are in the View menu).
    private var closeWarningsShortcut: some View {
        ZStack {
            if visibleDocumentProblem != nil || visibleAlert != nil {
                Button("Close Warnings") {
                    closedDocumentProblem = visibleDocumentProblem ?? closedDocumentProblem
                    closedAlert = visibleAlert ?? closedAlert
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Edit mode

struct EditView: View {
    @EnvironmentObject private var model: ShowModel
    @Binding var section: EditSection

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<EditSection?>(get: { section }, set: { if let new = $0 { section = new } })) {
                Section {
                    ForEach(EditSection.allCases) { item in
                        sidebarRow(item).tag(item)
                    }
                } header: {
                    Text(model.set.name).font(TrigType.groupHeader)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            switch section {
            case .songs: SetEditorView()
            case .destinations: DestinationsView()
            case .timecode: TimecodeView()
            case .fireLog: FireLogView()
            }
        }
    }

    private func sidebarRow(_ item: EditSection) -> some View {
        HStack {
            Label(item.rawValue, systemImage: item.symbol).font(TrigType.body)
            Spacer()
            if item == .destinations, model.set.destinations.contains(where: { model.reachability(of: $0.id).isOffline }) {
                StateDot(color: StateColor.alert, size: 8).accessibilityLabel("A Destination has no reply")
            }
            if let count = count(item) {
                Text("\(count)").font(TrigType.secondary.monospacedDigit()).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func count(_ item: EditSection) -> Int? {
        switch item {
        case .songs: return model.set.songs.count
        case .destinations: return model.set.destinations.count
        case .timecode, .fireLog: return nil
        }
    }
}

// MARK: - Toolbar source status

/// What the live source is doing, as the toolbar and Show screen say it.
struct SourceState {
    let color: Color
    let title: String
    let detail: String

    @MainActor
    init(_ model: ShowModel) {
        let live = (model.liveSource == .backup ? model.backupSource : nil) ?? model.source
        let rate = model.frameRate.map { "\($0.rawValue) fps" } ?? ""
        if live == .simulator {
            color = StateColor.caution
            title = "Simulator"
            detail = model.simulator.isPlaying ? "Playing, \(model.simulator.frameRate.rawValue) fps" : "Stopped"
        } else if !model.isReceiving {
            color = StateColor.alert
            title = "No signal"
            detail = "Holding the last frame"
        } else if model.liveSource == .backup {
            color = StateColor.caution
            title = "Following Backup \(live.kindName)"
            detail = "Primary \(model.source.kindName) lost"
        } else {
            color = StateColor.ok
            title = "Receiving \(live.kindName)"
            detail = rate
        }
    }
}

extension TimecodeSourceChoice {
    var kindName: String {
        switch self {
        case .simulator: return "Simulator"
        case .ltc: return "LTC"
        case .mtc: return "MTC"
        case .artNet: return "Art-Net"
        }
    }
}

struct SourceStatusLabel: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        let state = SourceState(model)
        HStack(spacing: 8) {
            StateDot(color: state.color)
            Text(state.title).font(.body.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Banners

/// A red banner. Timecode and Destination problems pulse (unless Reduce
/// Motion is on) and go away by themselves when fixed.
struct Banner: View {
    let text: String
    let pulses: Bool
    let onClose: () -> Void
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.body.weight(.bold))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.white)
            .help("Close this warning (Esc). It shows again if the problem changes.")
            .accessibilityLabel("Close warning")
        }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundColor(.white)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StateColor.alert))
            .opacity(dim ? 0.35 : 1)
            .padding([.horizontal, .top], 16)
            .textSelection(.enabled)
            .onAppear {
                guard pulses, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

// MARK: - Previous Versions

/// The Set's automatically kept earlier versions, newest first, grouped by day.
struct PreviousVersionsView: View {
    @EnvironmentObject private var model: ShowModel
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var selection: URL?

    struct Row: Identifiable {
        let version: SetVersion
        let summary: String
        var id: URL { version.url }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Previous Versions").font(TrigType.sectionTitle)
            Text("TrigIT keeps a version when the Set is opened and every two minutes while you edit, up to 100. Restoring saves the current Set as a version first.")
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                Text("No previous versions yet.").font(TrigType.body).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List(selection: $selection) {
                    ForEach(days, id: \.title) { day in
                        Section {
                            ForEach(day.rows) { row in
                                versionRow(row).tag(row.id)
                            }
                        } header: {
                            Text(day.title).font(TrigType.groupHeader).foregroundColor(.secondary)
                        }
                    }
                }
                .frame(minHeight: 320)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .capsuleButton()
                Button("Restore") {
                    if let row = rows.first(where: { $0.id == selection }) { model.restore(row.version) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .prominentCapsuleButton()
                .disabled(selection == nil || model.isShowLocked)
            }
        }
        .padding(26)
        .frame(width: 680)
        .onAppear(perform: load)
    }

    private func versionRow(_ row: Row) -> some View {
        HStack(spacing: 12) {
            Text(row.version.date.formatted(date: .omitted, time: .shortened))
                .font(TrigType.rowTitle.monospacedDigit())
                .frame(width: 64, alignment: .leading)
            Text(row.summary).font(TrigType.body).lineLimit(1)
            Spacer()
            if row.version.usedInShow {
                HStack(spacing: 6) {
                    StateDot(color: StateColor.caution, size: 8)
                    Text("Used in a show").font(TrigType.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var days: [(title: String, rows: [Row])] {
        let calendar = Calendar.current
        var result: [(title: String, rows: [Row])] = []
        for row in rows {
            let date = row.version.date
            let title = calendar.isDateInToday(date) ? "Today"
                : calendar.isDateInYesterday(date) ? "Yesterday"
                : date.formatted(date: .complete, time: .omitted)
            if result.last?.title == title { result[result.count - 1].rows.append(row) } else { result.append((title, [row])) }
        }
        return result
    }

    /// Reads every version once to describe what changed since the one before it.
    private func load() {
        let versions = model.previousVersions
        let sets = versions.map { try? SetFile.read(from: $0.url) }
        rows = versions.indices.map { index in
            let older = index + 1 < sets.count ? sets[index + 1] : nil
            let summary = sets[index].map { SetChangeSummary.describe(from: older, to: $0) } ?? "Can't be read"
            return Row(version: versions[index], summary: summary)
        }
    }
}

// MARK: - Timecode field

/// A text field for hh:mm:ss:ff. Valid text is offered to `onCommit` as you
/// type; text that isn't a timecode, or a value `onCommit` refuses, turns red.
/// When the value changes elsewhere (capture, undo) the text follows.
struct TimecodeField: View {
    let label: String
    let value: Timecode
    var font: Font = Font.title2.weight(.semibold).monospacedDigit()
    var width: CGFloat = 170
    let onCommit: (Timecode) -> Bool
    @State private var text: String
    @State private var refused = false

    init(_ label: String, value: Timecode, font: Font = Font.title2.weight(.semibold).monospacedDigit(),
         width: CGFloat = 170, onCommit: @escaping (Timecode) -> Bool) {
        self.label = label
        self.value = value
        self.font = font
        self.width = width
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
        .largeField()
        .font(font)
        .foregroundColor(Timecode(text) == nil || refused ? StateColor.alert : .primary)
        .frame(width: width)
        .onChange(of: value) { newValue in
            text = newValue.description
            refused = false
        }
    }
}
