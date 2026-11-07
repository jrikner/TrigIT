import SwiftUI
import TrigITEngine

/// Destinations on the left; the selected one's address, MIDI and DMX on the right.
struct DestinationsView: View {
    @EnvironmentObject private var model: ShowModel
    @State private var selection: DestinationID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.set.destinations) { destination in
                        row(destination).tag(destination.id)
                    }
                }
                .listStyle(.inset)
                RowDivider()
                HStack {
                    Button {
                        model.addDestination()
                        selection = model.set.destinations.last?.id
                    } label: { Label("Destination", systemImage: "plus") }
                    Spacer()
                    let inUse = selection.map(model.set.isInUse) ?? false
                    Button {
                        if let selection { model.deleteDestination(selection) }
                        selection = nil
                    } label: { Label("Delete Destination", systemImage: "minus").labelStyle(.iconOnly) }
                    .disabled(selection == nil || inUse)
                    .help(inUse ? "Used by an Action; remove those Actions first" : "Delete the selected Destination")
                }
                .capsuleButton()
                .disabled(model.isShowLocked)
                .padding(12)
            }
            .frame(width: 340)
            .overlay(alignment: .trailing) { Rectangle().fill(Surface.hairline).frame(width: 1) }

            Group {
                if let selection, let destination = model.set.destination(selection) {
                    DestinationDetail(destination: destination).id(destination.id)
                } else {
                    Text("Select a Destination").font(TrigType.body).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = model.set.destinations.first?.id } }
    }

    private func row(_ destination: Destination) -> some View {
        let state = model.reachability(of: destination.id)
        return HStack(spacing: 10) {
            StateDot(color: state.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(destination.name).font(TrigType.rowTitle).lineLimit(1)
                Text(destination.transports).font(TrigType.secondary).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if state != .reachable {
                Text(state.word).font(TrigType.secondary).foregroundColor(state == .noReply ? StateColor.alert : .secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

extension Destination {
    /// "OSC 10.0.0.21:7000, IAC Bus 1, Art-Net"
    var transports: String {
        (["OSC \(host):\(port)"] + [midiOutput?.name, dmxOutput?.name].compactMap { $0 }).joined(separator: ", ")
    }
}

struct DestinationDetail: View {
    @EnvironmentObject private var model: ShowModel
    let destination: Destination

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: binding(\.name))
                        .textFieldStyle(.plain)
                        .font(TrigType.pageTitle)
                    status
                }
                VStack(alignment: .leading, spacing: 8) {
                    GroupHeader("Network (OSC)")
                    GroupedBox {
                        FormRow(label: "Address") {
                            TextField("IP address", text: binding(\.host))
                                .textFieldStyle(TrigFieldStyle())
                                .font(TrigType.body.monospacedDigit())
                                .frame(width: 220)
                        }
                        RowDivider()
                        FormRow(label: "Port") { PortField(destination: destination) }
                        RowDivider()
                        FormRow(label: "Reply port") { ReplyPortField(destination: destination) }
                        RowDivider()
                        FormRow(label: "Network interface") {
                            InterfacePicker(destination: destination, selection: binding(\.networkInterface)).frame(width: 260)
                        }
                    }
                    Footnote("A reply on the reply port marks the Destination Reachable. Leave it empty if the device sends none.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    GroupHeader("MIDI")
                    GroupedBox {
                        FormRow(label: "Output") {
                            MIDIOutputPicker(destination: destination, selection: binding(\.midiOutput)).frame(width: 260)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    GroupHeader("DMX")
                    GroupedBox {
                        FormRow(label: "Protocol") {
                            Picker("DMX output", selection: binding(\.dmxOutput)) {
                                Text("None").tag(DMXOutput?.none)
                                ForEach(DMXOutput.allCases, id: \.self) { Text($0.name).tag(DMXOutput?.some($0)) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    Footnote("For pulse Actions. Art-Net goes to the address (a node, or a broadcast address such as 2.255.255.255); sACN multicast ignores it; sACN unicast uses it. Both use the chosen network interface.")
                }
                HStack(spacing: 16) {
                    Button("Send Test") { model.testDestination(destination) }
                        .capsuleButton()
                        .help("Send the OSC message /trigit/test to this Destination")
                    Text(usage).font(TrigType.secondary).foregroundColor(.secondary)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 32, bottom: 28, trailing: 32))
            .disabled(model.isShowLocked)
        }
    }

    private var status: some View {
        let state = model.reachability(of: destination.id)
        let monitor = model.destinationStatuses[destination.id]
        let detail: String = {
            if case .offline = monitor, let monitor { return ShowModel.statusText(monitor).capitalizedFirst }
            if let send = model.destinationSends[destination.id] {
                return send.ok ? "Last send at \(send.date.formatted(date: .omitted, time: .standard))" : (send.errorText ?? "")
            }
            return state == .reachable ? "Replying" : "Nothing sent yet"
        }()
        return HStack(spacing: 8) {
            StateDot(color: state.color)
            Text(state.word).font(TrigType.body).foregroundColor(state == .noReply ? StateColor.alert : .primary)
            Text(detail).font(TrigType.body).foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var usage: String {
        let users = model.set.songs.map { song in
            (song.startActions + song.stopActions).filter { $0.destinationID == destination.id }.count
        }
        let songs = users.filter { $0 > 0 }.count
        let actions = users.reduce(0, +)
        guard actions > 0 else { return "Not used by any Action" }
        return "Used by \(songs) Song\(songs == 1 ? "" : "s") in \(actions) Action\(actions == 1 ? "" : "s")"
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Destination, Value>) -> Binding<Value> {
        Binding(
            get: { destination[keyPath: keyPath] },
            set: { value in
                var edited = destination
                edited[keyPath: keyPath] = value
                model.update(edited)
            }
        )
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The port, kept as typed text so a half-typed or invalid value can show red
/// without being applied.
struct PortField: View {
    @EnvironmentObject private var model: ShowModel
    let destination: Destination
    @State private var text: String

    init(destination: Destination) {
        self.destination = destination
        _text = State(initialValue: String(destination.port))
    }

    var body: some View {
        TextField("Port", text: Binding(
            get: { text },
            set: { newText in
                text = newText
                if let port = UInt16(newText), port > 0 {
                    var edited = destination
                    edited.port = port
                    model.update(edited)
                }
            }
        ))
        .labelsHidden()
        .textFieldStyle(TrigFieldStyle())
        .font(TrigType.body.monospacedDigit())
        .frame(width: 220)
        .foregroundColor(UInt16(text).map { $0 > 0 } == true ? .primary : StateColor.alert)
        .onChange(of: destination.port) { text = String($0) }
    }
}

/// The optional port the device sends OSC replies to; empty for none.
struct ReplyPortField: View {
    @EnvironmentObject private var model: ShowModel
    let destination: Destination
    @State private var text: String

    init(destination: Destination) {
        self.destination = destination
        _text = State(initialValue: destination.replyPort.map(String.init) ?? "")
    }

    private var isValid: Bool { text.isEmpty || UInt16(text).map { $0 > 0 } == true }

    var body: some View {
        TextField("None", text: Binding(
            get: { text },
            set: { newText in
                text = newText
                guard isValid else { return }
                var edited = destination
                edited.replyPort = UInt16(newText)
                model.update(edited)
            }
        ))
        .labelsHidden()
        .textFieldStyle(TrigFieldStyle())
        .font(TrigType.body.monospacedDigit())
        .frame(width: 220)
        .foregroundColor(isValid ? .primary : StateColor.alert)
        .help("Where the device sends OSC replies (Resolume's OSC output, a grandMA3). A reply marks it online. Leave empty if it sends none.")
        .onChange(of: destination.replyPort) { text = $0.map(String.init) ?? "" }
    }
}

struct InterfacePicker: View {
    @EnvironmentObject private var model: ShowModel
    let destination: Destination
    let selection: Binding<String?>

    var body: some View {
        Picker("Network interface", selection: selection) {
            Text("Automatic (macOS decides)").tag(String?.none)
            ForEach(interfaceChoices, id: \.self) { name in
                Text(label(for: name)).tag(String?.some(name))
            }
        }
        .labelsHidden()
    }

    /// Available interfaces, plus the chosen one if it has disappeared so the
    /// choice stays visible (and flagged) instead of silently changing.
    private var interfaceChoices: [String] {
        var names = model.networkInterfaces.map(\.name)
        if let chosen = destination.networkInterface, !names.contains(chosen) {
            names.append(chosen)
        }
        return names
    }

    private func label(for name: String) -> String {
        model.networkInterfaces.first { $0.name == name }?.label ?? "\(name) (not available)"
    }
}

struct MIDIOutputPicker: View {
    @EnvironmentObject private var model: ShowModel
    let destination: Destination
    let selection: Binding<MIDIPortReference?>

    var body: some View {
        Picker("MIDI output", selection: selection) {
            Text("None").tag(MIDIPortReference?.none)
            ForEach(model.midiOutputs) { output in
                // Match by unique ID, so a renamed port still shows as chosen.
                let isChosen = destination.midiOutput?.uniqueID == output.uniqueID
                Text(output.name).tag(MIDIPortReference?.some(isChosen ? destination.midiOutput! : output.reference))
            }
            // Keep an unplugged output visible rather than silently clearing it.
            if let chosen = destination.midiOutput,
               !model.midiOutputs.contains(where: { $0.uniqueID == chosen.uniqueID }) {
                Text("\(chosen.name) (not connected)").tag(MIDIPortReference?.some(chosen))
            }
        }
        .labelsHidden()
        .help("For MIDI note and MIDI Show Control Actions")
    }
}
