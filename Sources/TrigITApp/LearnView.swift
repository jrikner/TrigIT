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
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(hint).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox("MIDI inputs") {
                VStack(alignment: .leading) {
                    if model.midiSources.isEmpty {
                        Text("No MIDI sources").foregroundColor(.secondary)
                    }
                    ForEach(model.midiSources) { source in
                        Toggle(source.name, isOn: included(source.uniqueID))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if listensForOSC {
                GroupBox("OSC") {
                    HStack {
                        Text("Port")
                        TextField("Port", value: $oscPort, format: .number.grouping(.never))
                            .frame(width: 70)
                            .foregroundColor(portIsValid ? .primary : .red)
                            .accessibilityLabel("OSC port")
                        Picker("Interface", selection: $oscInterface) {
                            Text("Any interface").tag("")
                            ForEach(model.networkInterfaces) { Text($0.label).tag($0.name) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Group {
                if let secondsLeft = learner.secondsLeft {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Listening… \(secondsLeft) s")
                    }
                } else if let problem = learner.problem {
                    Text(problem).foregroundColor(.red)
                }
            }
            .frame(minHeight: 20)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if learner.isListening {
                    Button("Stop") { learner.stop() }
                } else {
                    Button("Learn") { start() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 440)
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
