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
            }
            HStack {
                Text("Name").frame(width: 120, alignment: .leading)
                Text("Address").frame(maxWidth: .infinity, alignment: .leading)
                Text("Port").frame(width: 64, alignment: .leading)
                Text("Network interface").frame(width: 170, alignment: .leading)
                Spacer().frame(width: 24)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)

            List {
                ForEach(model.set.destinations) { destination in
                    DestinationRow(destination: destination)
                }
            }
        }
        .padding(8)
    }
}

struct DestinationRow: View {
    @EnvironmentObject private var model: ShowModel
    let destination: Destination
    @State private var portText: String

    init(destination: Destination) {
        self.destination = destination
        _portText = State(initialValue: String(destination.port))
    }

    private var inUse: Bool { model.set.isInUse(destination.id) }

    var body: some View {
        HStack {
            TextField("Name", text: binding(\.name))
                .frame(width: 120)
            TextField("IP address", text: binding(\.host))
                .font(.system(.body, design: .monospaced))
            TextField("Port", text: Binding(
                get: { portText },
                set: { text in
                    portText = text
                    if let port = UInt16(text), port > 0 {
                        var edited = destination
                        edited.port = port
                        model.update(edited)
                    }
                }
            ))
            .font(.system(.body, design: .monospaced))
            .foregroundColor(UInt16(portText).map { $0 > 0 } == true ? .primary : .red)
            .frame(width: 64)

            Picker("", selection: binding(\.networkInterface)) {
                Text("Automatic (macOS decides)").tag(String?.none)
                ForEach(interfaceChoices, id: \.self) { name in
                    Text(label(for: name)).tag(String?.some(name))
                }
            }
            .labelsHidden()
            .frame(width: 170)

            Button(role: .destructive) {
                model.deleteDestination(destination.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(inUse)
            .help(inUse ? "Used by an Action; remove those Actions first" : "Delete this Destination")
            .frame(width: 24)
        }
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
