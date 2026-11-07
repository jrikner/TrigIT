import SwiftUI
import TrigITEngine

/// Named Destinations, each with an address, a port and the network interface
/// its traffic must leave through.
struct DestinationsView: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Destinations").font(.headline)
                Spacer()
                Button("Add Destination") { model.addDestination() }
                    .disabled(model.isShowLocked)
            }

            // A Table keeps headers aligned, lets columns be resized, and
            // scrolls sideways instead of clipping when the pane is narrow.
            Table(model.set.destinations) {
                TableColumn("Name") { destination in
                    TextField("Name", text: binding(destination, \.name))
                        .labelsHidden()
                }
                .width(min: 80, ideal: 120)
                TableColumn("Address") { destination in
                    TextField("IP address", text: binding(destination, \.host))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 100, ideal: 140)
                TableColumn("Port") { destination in
                    PortField(destination: destination)
                }
                .width(min: 56, ideal: 64, max: 80)
                TableColumn("Reply Port") { destination in
                    ReplyPortField(destination: destination)
                }
                .width(min: 56, ideal: 72, max: 90)
                TableColumn("Network Interface") { destination in
                    InterfacePicker(destination: destination, selection: binding(destination, \.networkInterface))
                }
                .width(min: 110, ideal: 170)
                TableColumn("MIDI Output") { destination in
                    MIDIOutputPicker(destination: destination, selection: binding(destination, \.midiOutput))
                }
                .width(min: 100, ideal: 170)
                TableColumn("DMX") { destination in
                    Picker("DMX output", selection: binding(destination, \.dmxOutput)) {
                        Text("None").tag(DMXOutput?.none)
                        ForEach(DMXOutput.allCases, id: \.self) { output in
                            Text(output.name).tag(DMXOutput?.some(output))
                        }
                    }
                    .labelsHidden()
                    .help("For pulse Actions. Art-Net goes to the address (a node, or a broadcast address such as 2.255.255.255); sACN multicast ignores it; sACN unicast uses it. Both use the chosen network interface.")
                }
                .width(min: 90, ideal: 140)
                TableColumn("") { destination in
                    let inUse = model.set.isInUse(destination.id)
                    Button(role: .destructive) {
                        model.deleteDestination(destination.id)
                    } label: {
                        Label("Delete Destination", systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(inUse)
                    .help(inUse ? "Used by an Action; remove those Actions first" : "Delete this Destination")
                }
                .width(24)
            }
            .disabled(model.isShowLocked)
        }
        .padding(8)
    }

    private func binding<Value>(_ destination: Destination, _ keyPath: WritableKeyPath<Destination, Value>) -> Binding<Value> {
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
        .font(.system(.body, design: .monospaced))
        .foregroundColor(UInt16(text).map { $0 > 0 } == true ? .primary : .red)
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
        .font(.system(.body, design: .monospaced))
        .foregroundColor(isValid ? .primary : .red)
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
