// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI
import TrigITEngine
import TrigITProtocols

/// Listens for one message to learn. It opens its own Core MIDI clients and
/// its own UDP socket, so the timecode and MIDI notes inputs are untouched,
/// and closes them all as soon as a message is learned, it times out, or it
/// is stopped.
@MainActor
final class Learner: ObservableObject {
    /// Seconds until Learn gives up, while listening.
    @Published private(set) var secondsLeft: Int?
    /// Why Learn stopped or couldn't listen everywhere asked.
    @Published private(set) var problem: String?

    private var midiInputs: [MIDIInput] = []
    private var oscInput: ArtNetTimecodeInput?
    private var timer: Timer?
    private var accept: ((MIDIMessage?, [UInt8]?) -> Bool)?

    var isListening: Bool { secondsLeft != nil }

    /// Listens on the MIDI sources and, if given, the OSC port until `accept`
    /// returns true for a MIDI message or an OSC packet, `Learn.timeout`
    /// passes, or `stop()`.
    func start(midiSources: [Int32], osc: (port: UInt16, interface: String?)?,
               accept: @escaping (MIDIMessage?, [UInt8]?) -> Bool) {
        stop()
        problem = nil
        var problems: [String] = []
        for id in midiSources {
            let input = MIDIInput()
            var parser = MIDIParser()
            input.onBytes = { [weak self] bytes, _ in
                for message in parser.parse(bytes) { self?.offer(message, nil) }
            }
            if input.connect(to: id) { midiInputs.append(input) } else { problems.append("a MIDI input is not connected") }
        }
        if let osc {
            // Sharing Art-Net's port could take Art-Net Timecode packets away from the timecode input.
            if osc.port == artNetPort {
                problems.append("OSC port \(artNetPort) is Art-Net's, choose another")
            } else {
                let input = ArtNetTimecodeInput()
                input.onPacket = { [weak self] packet, _ in self?.offer(nil, packet) }
                do {
                    try input.start(interface: osc.interface, port: osc.port)
                    oscInput = input
                } catch {
                    problems.append("OSC: \(error.localizedDescription)")
                }
            }
        }
        problem = problems.isEmpty ? nil : "Not listening everywhere: " + problems.joined(separator: "; ")
        guard !midiInputs.isEmpty || oscInput != nil else {
            problem = problem ?? "Choose a MIDI input" + (osc == nil ? "." : " or an OSC port.")
            return
        }
        self.accept = accept
        let deadline = ProcessInfo.processInfo.systemUptime + Learn.timeout
        secondsLeft = Int(Learn.timeout)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let left = deadline - ProcessInfo.processInfo.systemUptime
                if left <= 0 {
                    self.stop()
                    self.problem = "Nothing arrived in \(Int(Learn.timeout)) seconds."
                } else {
                    self.secondsLeft = Int(left.rounded(.up))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        midiInputs.removeAll()
        oscInput?.stop()
        oscInput = nil
        timer?.invalidate()
        timer = nil
        accept = nil
        secondsLeft = nil
    }

    private func offer(_ midi: MIDIMessage?, _ packet: [UInt8]?) {
        guard let accept, accept(midi, packet) else { return }
        stop()
    }
}

/// Learn: listens on the chosen MIDI inputs (and an OSC port, for Actions)
/// until the first message `accept` takes, then closes.
struct LearnSheet: View {
    @EnvironmentObject private var model: ShowModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var learner = Learner()
    let title: String
    let hint: String
    let listensForOSC: Bool
    /// Returns true if the message was learned.
    let accept: (MIDIMessage?, [UInt8]?) -> Bool

    /// Unique IDs of the MIDI sources turned off, so new sources start on.
    @AppStorage("learnMIDIExcluded") private var excludedText = ""
    @AppStorage("learnOSCPort") private var oscPort = 8000
    /// BSD name, or empty for every interface.
    @AppStorage("learnOSCInterface") private var oscInterface = ""

    private var excluded: Set<Int32> { Set(excludedText.split(separator: ",").compactMap { Int32($0) }) }
    private var portIsValid: Bool { (1...65535).contains(oscPort) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(TrigType.sectionTitle)
            Text(hint).font(.system(size: 16)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                GroupHeader("MIDI inputs")
                GroupedBox {
                    if model.midiSources.isEmpty {
                        FormRow(label: "No MIDI sources") { EmptyView() }.foregroundColor(.secondary)
                    }
                    ForEach(Array(model.midiSources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 { RowDivider() }
                        FormRow(label: source.name) {
                            Toggle(source.name, isOn: included(source.uniqueID)).toggleStyle(.switch).labelsHidden()
                        }
                    }
                }
            }
            if listensForOSC {
                VStack(alignment: .leading, spacing: 8) {
                    GroupHeader("OSC")
                    GroupedBox {
                        FormRow(label: "Port") {
                            TextField("Port", value: $oscPort, format: .number.grouping(.never))
                                .labelsHidden()
                                .font(TrigType.body.monospacedDigit())
                                .frame(width: 100)
                                .foregroundColor(portIsValid ? .primary : StateColor.alert)
                                .accessibilityLabel("OSC port")
                        }
                        RowDivider()
                        FormRow(label: "Interface") {
                            Picker("Interface", selection: $oscInterface) {
                                Text("Any interface").tag("")
                                ForEach(model.networkInterfaces) { Text($0.label).tag($0.name) }
                            }
                            .labelsHidden()
                            .frame(width: 240)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if let secondsLeft = learner.secondsLeft {
                    ProgressView().controlSize(.small)
                    Text("Listening, \(secondsLeft) s left").font(TrigType.body).monospacedDigit()
                } else if let problem = learner.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(TrigType.body).foregroundColor(StateColor.alert)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .capsuleButton()
                if learner.isListening {
                    Button("Stop") { learner.stop() }.capsuleButton()
                } else {
                    Button("Learn") { start() }
                        .keyboardShortcut(.defaultAction)
                        .prominentCapsuleButton()
                }
            }
            .frame(minHeight: 36)
        }
        .padding(26)
        .frame(width: 560)
        .onAppear { start() }
        .onChange(of: oscPort) { _ in if learner.isListening { start() } }
        .onChange(of: oscInterface) { _ in if learner.isListening { start() } }
        .onDisappear { learner.stop() }
    }

    private func included(_ id: Int32) -> Binding<Bool> {
        Binding(
            get: { !excluded.contains(id) },
            set: { on in
                var ids = excluded
                if on { ids.remove(id) } else { ids.insert(id) }
                excludedText = ids.map(String.init).sorted().joined(separator: ",")
                if learner.isListening { start() }
            }
        )
    }

    private func start() {
        let sources = model.midiSources.map(\.uniqueID).filter { !excluded.contains($0) }
        let osc = listensForOSC && portIsValid ? (UInt16(oscPort), oscInterface.isEmpty ? nil : oscInterface) : nil
        learner.start(midiSources: sources, osc: osc) { midi, packet in
            guard accept(midi, packet) else { return false }
            dismiss()
            return true
        }
    }
}
