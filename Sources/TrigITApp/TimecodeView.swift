// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TrigITEngine

/// The Primary and Backup Sources side by side, Stop detection and the MIDI
/// notes input.
struct TimecodeView: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Timecode").font(TrigType.pageTitle).tracking(-0.4)
                HStack(alignment: .top, spacing: 20) {
                    SourceColumn(role: .primary)
                    SourceColumn(role: .backup)
                }
                VStack(alignment: .leading, spacing: 8) {
                    GroupHeader("Stop detection")
                    GroupedBox {
                        FormRow(label: "Treat silence as a Stop after") {
                            Stepper(value: Binding(get: { model.set.stopTime }, set: { model.setStopTime($0) }),
                                    in: ShowSet.stopTimeRange, step: 0.5) {
                                Text(String(format: "%g s", model.set.stopTime)).font(TrigType.body.monospacedDigit())
                            }
                            .disabled(model.isShowLocked)
                        }
                    }
                    Footnote("TrigIT follows Primary while it is healthy and switches to Backup when Primary is lost. Backup has to be a different type from Primary. Shorter gaps count as Dropouts and never re-fire a Song.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    GroupHeader("MIDI notes")
                    GroupedBox {
                        FormRow(label: "Start and Stop Notes from") {
                            Picker("MIDI notes", selection: Binding(
                                get: { model.noteSourceID },
                                set: { model.selectNoteSource($0) }
                            )) {
                                Text("None").tag(Int32?.none)
                                ForEach(noteOptions, id: \.self) { Text(model.noteSourceLabel($0)).tag(Optional($0)) }
                            }
                            .labelsHidden()
                            .frame(width: 280)
                        }
                    }
                    Footnote("It may be the same port as MTC.")
                }
            }
            .padding(EdgeInsets(top: 16, leading: 32, bottom: 28, trailing: 32))
        }
    }

    /// Every MIDI source, plus the chosen one if it is unplugged.
    private var noteOptions: [Int32] {
        var ids = model.midiSources.map(\.uniqueID)
        if let current = model.noteSourceID, !ids.contains(current) { ids.append(current) }
        return ids
    }
}

/// One source: its type, input, live readout, level and state.
struct SourceColumn: View {
    @EnvironmentObject private var model: ShowModel
    let role: SourceRole

    private var choice: TimecodeSourceChoice? { role == .primary ? model.source : model.backupSource }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(role == .primary ? "Primary" : "Backup").font(TrigType.sectionTitle)
                Spacer()
                if choice != nil {
                    let state = SourceRoleState(model, role)
                    HStack(spacing: 6) {
                        StateDot(color: state.color, size: 8)
                        Text(state.word).font(.system(size: 16, weight: .semibold)).foregroundColor(state.color)
                    }
                }
            }
            GroupedBox {
                FormRow(label: "Type") {
                    Picker("Type", selection: kindBinding) {
                        if role == .backup { Text("None").tag(TimecodeSourceKind?.none) }
                        ForEach(kinds, id: \.self) { kind in
                            Text(kind.name).tag(TimecodeSourceKind?.some(kind))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if let choice, choice != .simulator {
                    RowDivider()
                    FormRow(label: "Input") {
                        Picker("Input", selection: Binding(get: { choice }, set: select)) {
                            ForEach(inputs(of: choice.kind, current: choice), id: \.self) {
                                Text(model.sourceLabel($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 300)
                    }
                }
                if choice != nil {
                    RowDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                            Text(reading?.description ?? "00:00:00:00")
                                .font(TrigType.readout)
                                .foregroundColor(role == .backup || reading == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                        if choice != .simulator { LevelMeter(level: level) }
                        Text(footnote).font(TrigType.secondary).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var kinds: [TimecodeSourceKind] {
        [.ltc, .mtc, .artNet, .simulator].filter { role == .primary || $0 != model.source.kind }
    }

    private var kindBinding: Binding<TimecodeSourceKind?> {
        Binding(get: { choice?.kind }, set: { kind in
            guard let kind else { return model.selectBackupSource(nil) }
            guard kind != choice?.kind, let first = inputs(of: kind, current: nil).first else { return }
            select(first)
        })
    }

    private func select(_ new: TimecodeSourceChoice) {
        role == .primary ? model.selectSource(new) : model.selectBackupSource(new)
    }

    /// Every input of a kind, plus `current` if its device is unplugged, so a
    /// missing device stays visible rather than silently switching.
    private func inputs(of kind: TimecodeSourceKind, current: TimecodeSourceChoice?) -> [TimecodeSourceChoice] {
        var choices: [TimecodeSourceChoice]
        switch kind {
        case .simulator: choices = [.simulator]
        case .ltc: choices = model.audioInputDevices.flatMap { device in
            (0..<device.channelCount).map { TimecodeSourceChoice.ltc(deviceUID: device.uid, channel: $0) }
        }
        case .mtc: choices = model.midiSources.map { .mtc(sourceID: $0.uniqueID) }
        case .artNet: choices = [.artNet(interface: nil)] + model.networkInterfaces.map { .artNet(interface: $0.name) }
        }
        if let current, current.kind == kind, !choices.contains(current) { choices.append(current) }
        return choices
    }

    private var reading: Timecode? {
        choice == .simulator ? model.simulator.position(at: model.now) : model.sourceReadings[role]
    }

    private var healthy: Bool { model.healthySources.contains(role) }

    private var level: Double {
        guard healthy else { return 0 }
        if case .ltc = choice { return Double(model.ltcLevel) }
        return 0.7 // MTC and Art-Net have no level: packets are arriving or not.
    }

    private var footnote: String {
        guard let choice else { return "" }
        let rate = model.frameRate.map { ", \($0.rawValue) fps" } ?? ""
        switch choice {
        case .simulator: return "The Simulator replaces live timecode"
        case .ltc:
            guard healthy, model.ltcLevel > 0 else { return "No LTC on this input" }
            return String(format: "Signal level %.0f dBFS%@", 20 * log10(Double(model.ltcLevel)), rate)
        case .mtc: return healthy ? "Quarter-frames arriving\(rate)" : "No MTC on this input"
        case .artNet: return healthy ? "Art-Net Timecode packets arriving\(rate)" : "No Art-Net Timecode on this interface"
        }
    }
}

extension TimecodeSourceKind {
    var name: String {
        switch self {
        case .ltc: return "LTC"
        case .mtc: return "MTC"
        case .artNet: return "Art-Net"
        case .simulator: return "Simulator"
        }
    }
}

/// A 30-segment meter, the last six orange.
struct LevelMeter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<30, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Double(index) < level * 30
                          ? (index >= 24 ? StateColor.caution : StateColor.ok)
                          : Color.white.opacity(0.1))
                    .frame(height: 10)
            }
        }
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

// MARK: - Fire Log

struct FireLogView: View {
    @EnvironmentObject private var model: ShowModel
    @State private var filter = Filter.all
    @State private var search = ""

    enum Filter: String, CaseIterable {
        case all = "All", fired = "Fired", failed = "Failed", dropouts = "Dropouts"

        func includes(_ kind: ShowModel.LogEntry.Kind) -> Bool {
            switch self {
            case .all: return true
            case .fired: return kind == .fired
            case .failed: return kind == .failed || kind == .problem
            case .dropouts: return kind == .dropout
            }
        }
    }

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private var entries: [ShowModel.LogEntry] {
        model.log.filter { filter.includes($0.kind) && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { filter in
                        Text("\(filter.rawValue) \(model.log.filter { filter.includes($0.kind) }.count)").tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)

            VStack(spacing: 0) {
                header
                RowDivider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry)
                                .background(entry.kind == .failed || entry.kind == .problem
                                            ? StateColor.alert.opacity(0.16)
                                            : Color.white.opacity(index.isMultiple(of: 2) ? 0 : 0.03))
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search the Fire Log")
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("Time").frame(width: 150, alignment: .leading)
            Text("Timecode").frame(width: 150, alignment: .leading)
            Text("Event").frame(width: 150, alignment: .leading)
            Text("Detail")
            Spacer()
        }
        .font(TrigType.groupHeader)
        .foregroundColor(.secondary)
        .padding(.horizontal, 32)
        .padding(.vertical, 8)
    }

    private func row(_ entry: ShowModel.LogEntry) -> some View {
        HStack(spacing: 16) {
            Text(Self.timeFormat.string(from: entry.date))
                .font(.system(size: 16).monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(entry.timecode?.description ?? "")
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .frame(width: 150, alignment: .leading)
            Label(entry.kind.rawValue, systemImage: entry.kind.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(entry.kind.color, .primary)
                .frame(width: 150, alignment: .leading)
            Text(entry.text).font(.system(size: 17)).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}

extension ShowModel.LogEntry.Kind {
    var symbol: String {
        switch self {
        case .fired, .sent: return "checkmark.circle.fill"
        case .failed, .problem: return "xmark.circle.fill"
        case .dropout: return "exclamationmark.triangle.fill"
        case .stop: return "stop.circle.fill"
        case .failover: return "arrow.left.arrow.right.circle.fill"
        case .armed: return "bolt.fill"
        case .disarmed: return "bolt.slash"
        case .info: return "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .fired, .sent: return StateColor.ok
        case .failed, .problem, .armed: return StateColor.alert
        case .dropout, .failover: return StateColor.caution
        case .stop, .disarmed, .info: return StateColor.idle
        }
    }
}
