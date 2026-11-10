// SPDX-License-Identifier: GPL-3.0-or-later

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
                .contextMenu(forSelectionType: DestinationID.self) { ids in
                    if let id = ids.first, ids.count == 1, let destination = model.set.destination(id) {
                        Button("Send Test") { model.testDestination(destination) }
                        Divider()
                        Button("Delete Destination", role: .destructive) {
                            selection = id
                            deleteSelected()
                        }
                        .disabled(model.isShowLocked || model.set.isInUse(id))
                    }
                }
                .onDeleteCommand {
                    if let selection, !model.isShowLocked, !model.set.isInUse(selection) { deleteSelected() }
                }
                RowDivider()
                HStack {
                    let inUse = selection.map(model.set.isInUse) ?? false
                    AddRemoveButtons(add: "New Destination",
                                     remove: inUse ? "Used by an Action; remove those Actions first" : "Delete Destination",
                                     canRemove: selection != nil && !inUse) {
                        model.addDestination()
                        selection = model.set.destinations.last?.id
                    } onRemove: {
                        deleteSelected()
                    }
                    Spacer()
                }
                .disabled(model.isShowLocked)
                .padding(8)
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 340)
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
        .onAppear {
            if selection == nil { selection = model.set.destinations.first?.id }
            selectRequested()
        }
        .onChange(of: model.destinationToSelect) { _ in selectRequested() }
    }

    /// New Destination from the menu bar.
    private func selectRequested() {
        guard let id = model.destinationToSelect else { return }
        model.destinationToSelect = nil
        selection = id
    }

    /// Asks first; the in-use rule disables the button before it gets here.
    private func deleteSelected() {
        guard let selection, let destination = model.set.destination(selection),
              confirmDelete("Delete \u{201C}\(destination.name)\u{201D}?",
                            detail: "Its address, ports and MIDI and DMX settings will be deleted.")
        else { return }
        model.deleteDestination(selection)
        self.selection = nil
    }

    private func row(_ destination: Destination) -> some View {
        let state = model.reachability(of: destination.id)
        return HStack(spacing: 10) {
            StateDot(color: state.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(destination.name).font(TrigType.rowTitle).lineLimit(1)
                Text(destination.transportSummary).font(TrigType.secondary).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if case .online = state {} else {
                Text(state.word).font(TrigType.secondary).foregroundColor(state.isOffline ? StateColor.alert : .secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

extension Destination {
    /// What is switched on: "OSC 10.0.0.21:7000, IAC Bus 1, Art-Net".
    var transportSummary: String {
        transports.map { transport in
            switch transport {
            case .osc: return "OSC \(host):\(port)"
            case .midi: return midiOutput?.name ?? "MIDI (no output)"
            case .dmx:
                guard let output = dmxOutput else { return "DMX" }
                return output == .sACNMulticast ? output.name : "\(output.name) \(dmxHost)"
            }
        }.joined(separator: ", ")
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
                section("Network (OSC)", .osc) {
                    GroupedBox {
                        FormRow(label: "Address") {
                            TextField("IP address", text: binding(\.host))
                                .textFieldStyle(.roundedBorder)
                                .font(TrigType.body.monospacedDigit())
                                .frame(width: 220)
                        }
                        RowDivider()
                        FormRow(label: "Port") { PortField(destination: destination) }
                        RowDivider()
                        FormRow(label: "Reply port") { ReplyPortField(destination: destination) }
                        RowDivider()
                        FormRow(label: "Network interface") {
                            InterfacePicker(selection: binding(\.networkInterface)).frame(width: 260)
                        }
                    }
                    Footnote("A reply on the reply port shows the Destination as Responding. Leave it empty if the device sends none.")
                }
                section("MIDI", .midi) {
                    GroupedBox {
                        FormRow(label: "Output") {
                            MIDIOutputPicker(destination: destination, selection: binding(\.midiOutput)).frame(width: 260)
                        }
                    }
                }
                section("DMX", .dmx) {
                    let output = destination.dmxOutput ?? .artNet
                    GroupedBox {
                        FormRow(label: "Protocol") {
                            Picker("DMX output", selection: binding(\.dmxOutput)) {
                                ForEach(DMXOutput.allCases, id: \.self) { Text($0.name).tag(DMXOutput?.some($0)) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        if output != .sACNMulticast {
                            RowDivider()
                            FormRow(label: "Address") {
                                TextField(output == .artNet ? "IP or broadcast address" : "IP address", text: binding(\.dmxHost))
                                    .textFieldStyle(.roundedBorder)
                                    .font(TrigType.body.monospacedDigit())
                                    .frame(width: 220)
                            }
                        }
                        RowDivider()
                        FormRow(label: "Network interface") {
                            InterfacePicker(selection: binding(\.dmxInterface)).frame(width: 260)
                        }
                        if output != .artNet {
                            RowDivider()
                            FormRow(label: "Priority") {
                                HStack(spacing: 8) {
                                    TextField("Priority", value: binding(\.sacnPriority), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .font(TrigType.body.monospacedDigit())
                                        .frame(width: 80)
                                    Stepper("Priority", value: binding(\.sacnPriority), in: Destination.sacnPriorityRange)
                                        .labelsHidden()
                                }
                                .help("0 to 200, default 100. Receivers take the source with the highest priority.")
                            }
                            RowDivider()
                            FormRow(label: "Source name") {
                                TextField(Destination.defaultDMXSourceName, text: binding(\.dmxSourceName))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)
                            }
                        }
                        RowDivider()
                        FormRow(label: "Refresh rate") {
                            HStack(spacing: 8) {
                                Text("\(Int(destination.dmxRefreshRate)) Hz")
                                    .font(TrigType.body.monospacedDigit())
                                    .frame(width: 60, alignment: .trailing)
                                Stepper("Refresh rate", value: binding(\.dmxRefreshRate), in: Destination.dmxRefreshRateRange, step: 1)
                                    .labelsHidden()
                            }
                            .help("How many times a second each universe is sent. Default 30.")
                        }
                    }
                    Footnote(output == .sACNMulticast
                        ? "For pulse Actions. sACN multicast sends each universe to its own group (239.255.x.y) through the chosen interface."
                        : "For pulse Actions. DMX has its own address and interface, apart from OSC: often a lighting network such as 2.x.x.x or 10.x.x.x.")
                }
                HStack(spacing: 16) {
                    Button(destination.usesOSC ? "Send Test" : "Check Now") { model.testDestination(destination) }
                        .capsuleButton()
                        .help(destination.usesOSC ? "Send the OSC message /trigit/test to this Destination and ping it"
                                                  : "Check this Destination's status now")
                    Text(usage).font(TrigType.secondary).foregroundColor(.secondary)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 32, bottom: 28, trailing: 32))
            .disabled(model.isShowLocked)
        }
    }

    /// A transport's section: its switch in the header, its settings only while it is on.
    private func section<Content: View>(_ title: String, _ transport: Transport,
                                        @ViewBuilder content: () -> Content) -> some View {
        let isOn = destination[uses: transport]
        let isLast = isOn && destination.transports.count == 1
        return VStack(alignment: .leading, spacing: 8) {
            GroupHeader(title: title) {
                Toggle(title, isOn: binding(\.[uses: transport]))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(isLast)
                    .help(isLast ? "At least one of OSC, MIDI and DMX stays on"
                                 : "Off: \(transport.name) Actions can't use this Destination; its settings are kept but ignored")
            }
            if isOn { content() }
        }
    }

    private var status: some View {
        let state = model.reachability(of: destination.id)
        let detail: String = {
            switch state {
            case .offline(.sendFailed(let error)): return error.capitalizedFirst
            case .offline: return ShowModel.statusText(state).capitalizedFirst
            case .online(.responding): return "An OSC reply arrived on the reply port"
            case .online(.hostAnswers): return "The host answers pings"
            case .online(.midiOutputConnected): return ""
            case .unknown, .sent:
                guard let send = model.destinationSends[destination.id] else { return "Not heard from yet" }
                return "Last send at \(send.date.formatted(date: .omitted, time: .standard))"
            }
        }()
        return HStack(spacing: 8) {
            StateDot(color: state.color)
            Text(state.word).font(TrigType.body).foregroundColor(state.isOffline ? StateColor.alert : .primary)
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
        .textFieldStyle(.roundedBorder)
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
        .textFieldStyle(.roundedBorder)
        .font(TrigType.body.monospacedDigit())
        .frame(width: 220)
        .foregroundColor(isValid ? .primary : StateColor.alert)
        .help("Where the device sends OSC replies (Resolume's OSC output, a grandMA3). A reply marks it online. Leave empty if it sends none.")
        .onChange(of: destination.replyPort) { text = $0.map(String.init) ?? "" }
    }
}

struct InterfacePicker: View {
    @EnvironmentObject private var model: ShowModel
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
        if let chosen = selection.wrappedValue, !names.contains(chosen) {
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
