// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import TrigITEngine
import TrigITProtocols
import TrigITStorage

/// File > Export > grandMA3 Timecode Show…: writes the Set as XML a grandMA3
/// imports itself, with a macro that imports it (MA3Export).
struct MA3ExportView: View {
    @EnvironmentObject private var model: ShowModel
    @Environment(\.dismiss) private var dismiss
    @State private var sequence = 101
    @State private var timecode = 101
    @State private var macro = 101
    @State private var slot = 1
    @State private var frameRate = FrameRate.fps30
    @State private var oscLines: [String: Int] = [:]
    @State private var problem: String?

    private var oscDestinations: [String] { MA3Export.oscDestinations(in: model.set) }
    private var options: MA3Export.Options {
        MA3Export.Options(sequence: sequence, timecode: timecode, macro: macro, slot: slot, frameRate: frameRate, oscLines: oscLines)
    }
    private var result: (cues: [MA3Export.Cue], warnings: [String]) {
        MA3Export.cues(for: model.set, frameRate: frameRate, oscLines: oscLines)
    }
    private var numbersValid: Bool {
        [sequence, timecode, macro].allSatisfy { $0 >= 1 } && oscLines.values.allSatisfy { $0 >= 1 }
    }

    var body: some View {
        let result = result
        VStack(alignment: .leading, spacing: 16) {
            Text("Export grandMA3 Timecode Show").font(TrigType.sectionTitle)
            Text("Writes the Set as a Sequence and a Timecode Show the console imports itself, with a macro that imports them. No TrigIT plugin is needed.")
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        GroupedBox {
                            FormRow(label: "Sequence") { numberField($sequence) }
                            RowDivider()
                            FormRow(label: "Timecode") { numberField($timecode) }
                            RowDivider()
                            FormRow(label: "Macro") { numberField($macro) }
                            RowDivider()
                            FormRow(label: "Timecode slot") {
                                Picker("Timecode slot", selection: $slot) {
                                    ForEach(1...16, id: \.self) { Text("Slot \($0)").tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 120)
                            }
                            RowDivider()
                            FormRow(label: "Frame rate") {
                                Picker("Frame rate", selection: $frameRate) {
                                    ForEach(FrameRate.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                        Footnote("The macro deletes Timecode \(timecode) and Sequence \(sequence), then imports the Set there. The frame rate is the incoming timecode's: it decides when Stop Actions fire.")
                    }
                    if !oscDestinations.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            GroupHeader("OSC lines")
                            GroupedBox {
                                ForEach(Array(oscDestinations.enumerated()), id: \.element) { index, name in
                                    if index > 0 { RowDivider() }
                                    FormRow(label: name) { numberField(lineBinding(name)) }
                                }
                            }
                            Footnote("The In & Out OSC line each Destination's cues send on. Set these lines up on the console: the README says how.")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        GroupHeader(result.warnings.isEmpty ? "Summary" : "\(result.warnings.count) warning\(result.warnings.count == 1 ? "" : "s")")
                        GroupedBox {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(result.cues.isEmpty ? "Nothing to export: no Action can be sent at a timecode."
                                     : "\(result.cues.count) cue\(result.cues.count == 1 ? "" : "s"), from \(result.cues[0].name).")
                                    .font(TrigType.body)
                                ForEach(result.warnings, id: \.self) { warning in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        StateDot(color: StateColor.caution, size: 8)
                                        Text(warning).font(TrigType.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    if let problem {
                        Text(problem).font(TrigType.secondary).foregroundColor(StateColor.alert)
                    }
                }
            }
            .frame(maxHeight: 520)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .capsuleButton()
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .prominentCapsuleButton()
                    .disabled(result.cues.isEmpty || !numbersValid)
            }
        }
        .padding(26)
        .frame(width: 680)
        .onAppear {
            frameRate = model.frameRate ?? .fps30
            for (index, name) in oscDestinations.enumerated() where oscLines[name] == nil { oscLines[name] = index + 1 }
        }
    }

    private func numberField(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .font(TrigType.body.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
    }

    private func lineBinding(_ name: String) -> Binding<Int> {
        Binding(get: { oscLines[name] ?? 1 }, set: { oscLines[name] = $0 })
    }

    /// Asks for a new folder and writes the files into it.
    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export grandMA3 Timecode Show"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "TrigIT \(model.set.name) for grandMA3"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in MA3Export.files(for: model.set, options: options) {
                try file.contents.write(to: folder.appendingPathComponent(file.name), options: .atomic)
            }
            model.record("Exported \(model.set.name) as a grandMA3 Timecode Show to \(folder.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            dismiss()
        } catch {
            problem = "Couldn't export: \(error.localizedDescription)"
            model.record(problem!, isError: true)
        }
    }
}
