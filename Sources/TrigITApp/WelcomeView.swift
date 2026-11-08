import AppKit
import SwiftUI
import TrigITEngine

/// First launch, and whenever no Set is open: start or open a Set.
struct WelcomeView: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                Image(nsImage: AppIcon.image)
                    .resizable()
                    .frame(width: 140, height: 140)
                    .accessibilityHidden(true)
                Text("TrigIT").font(.system(size: 40, weight: .bold)).padding(.top, 12)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.system(size: 16)).foregroundColor(.secondary)
                VStack(spacing: 4) {
                    action("New Set", "Start with an empty Set", symbol: "plus") { model.chooseAndCreateNew() }
                    action("Open Other…", "Choose a .trigit file", symbol: "folder") { model.chooseAndOpen() }
                    action("Import CSV…", "One Song per row: name, start, end", symbol: "tablecells") { model.chooseAndImportCSVAsNewSet() }
                    action("Open Example", "A small Set to explore", symbol: "book") { model.openExample() }
                }
                .frame(width: 440)
                .padding(.top, 28)
                if let url = model.documentURL {
                    Button("Back to \(url.deletingPathExtension().lastPathComponent)") { model.showingWelcome = false }
                        .capsuleButton()
                        .keyboardShortcut(.cancelAction)
                        .padding(.top, 20)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 440, alignment: .leading)
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity)

            FloatingPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Open Recent").font(TrigType.sectionTitle).padding(.horizontal, 10)
                    if model.recentDocuments.isEmpty {
                        Text("No recent Sets").font(TrigType.body).foregroundColor(.secondary).padding(10)
                    }
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.recentDocuments, id: \.self) { url in recent(url) }
                        }
                    }
                    Spacer(minLength: 0)
                    Footnote("Also in File, Open Recent").padding(.horizontal, 6)
                }
                .padding(16)
            }
            .frame(width: 420)
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(model.isShowLocked)
    }

    private func action(_ title: String, _ detail: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TrigType.rowTitle)
                    Text(detail).font(TrigType.secondary).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(HoverRowStyle())
    }

    private func recent(_ url: URL) -> some View {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)
            .map { $0.formatted(.relative(presentation: .named)) } ?? "missing"
        return Button { model.open(url) } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc").font(.system(size: 22)).foregroundColor(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent).font(TrigType.rowTitle).lineLimit(1)
                    Text("Changed \(modified)").font(TrigType.secondary).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

/// A plain row that highlights on hover and press.
struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.14 : hovering ? 0.07 : 0)))
            .onHover { hovering = $0 }
    }
}

// MARK: - Opening

/// Shown for every way a Set opens, at least 1.2 s (0.6 s with Reduce Motion).
struct OpeningView: View {
    @EnvironmentObject private var model: ShowModel
    let setName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0

    var body: some View {
        VStack(spacing: 28) {
            Image(nsImage: AppIcon.image)
                .resizable()
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            Text("Inshallah it will be a good show!")
                .font(.system(size: 60, weight: .bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Color.white.opacity(0.8)).frame(width: 260 * progress)
            }
            .frame(width: 260, height: 6)
            Text("Opening \(setName)…").font(.system(size: 18)).foregroundColor(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: setName) {
            let duration = reduceMotion ? 0.6 : 1.2
            withAnimation(reduceMotion ? nil : .easeInOut(duration: duration)) { progress = 1 }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { model.openingSetName = nil }
        }
    }
}

// MARK: - New Set setup

/// After New Set: choose the timecode, a first Destination, and test it.
struct NewSetSetupView: View {
    @EnvironmentObject private var model: ShowModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = 1
    @State private var preset = Preset.resolume
    @State private var host = "127.0.0.1"
    @State private var port = "7000"
    @State private var destinationID = DestinationID()

    enum Preset: String, CaseIterable {
        case resolume = "Resolume", grandMA3 = "grandMA3", other = "Other"

        var detail: String {
            switch self {
            case .resolume: return "OSC column triggers"
            case .grandMA3: return "MIDI Show Control GO, DMX remote pulses"
            case .other: return "Any OSC, MIDI, Art-Net or sACN device"
            }
        }

        var port: String {
            switch self {
            case .resolume: return "7000"
            case .grandMA3: return "8000"
            case .other: return "9000"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    stepIndicator
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.system(size: 40, weight: .bold))
                        Text(subtitle).font(.system(size: 19)).foregroundColor(.secondary)
                    }
                    switch step {
                    case 1: SourceColumn(role: .primary)
                    case 2: presetStep
                    default: testStep
                    }
                }
                .frame(width: 900, alignment: .leading)
                .padding(40)
            }
            RowDivider()
            HStack {
                Button("Back") { step -= 1 }.capsuleButton().disabled(step == 1)
                Spacer()
                Button("Skip") { advance(adding: false) }.capsuleButton()
                Button(step == 3 ? "Done" : "Continue") { advance(adding: true) }
                    .prominentCapsuleButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 2 && UInt16(port).map { $0 > 0 } != true)
            }
            .padding(20)
        }
        .frame(width: 980, height: 680)
        .preferredColorScheme(.dark)
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(1...3, id: \.self) { index in
                Capsule()
                    .fill(index < step ? StateColor.ok : index == step ? Color.white.opacity(0.85) : Color.white.opacity(0.18))
                    .frame(width: 40, height: 5)
            }
            Text("Step \(step) of 3").font(TrigType.secondary).foregroundColor(.secondary).padding(.leading, 8)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch step {
        case 1: return "Which timecode should TrigIT follow?"
        case 2: return "Where should TrigIT send?"
        default: return "Test fire"
        }
    }

    private var subtitle: String {
        switch step {
        case 1: return "Choose the Primary Source. You can add a Backup later, in Timecode."
        case 2: return "Choose a preset. You can add more Destinations later."
        default: return "Send a test to the new Destination to check it arrives."
        }
    }

    private var presetStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                ForEach(Preset.allCases, id: \.self) { item in
                    Button {
                        preset = item
                        port = item.port
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.rawValue).font(TrigType.rowTitle)
                            Text(item.detail).font(TrigType.secondary).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(preset == item ? Color.white.opacity(0.85) : Surface.hairline, lineWidth: 2))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(preset == item ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                GroupHeader(preset.rawValue)
                GroupedBox {
                    FormRow(label: "Address") {
                        TextField("IP address", text: $host).textFieldStyle(TrigFieldStyle())
                            .font(TrigType.body.monospacedDigit()).frame(width: 220)
                    }
                    RowDivider()
                    FormRow(label: "OSC port") {
                        TextField("Port", text: $port).textFieldStyle(TrigFieldStyle())
                            .font(TrigType.body.monospacedDigit()).frame(width: 220)
                            .foregroundColor(UInt16(port).map { $0 > 0 } == true ? .primary : StateColor.alert)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var testStep: some View {
        if let destination = model.set.destination(destinationID) {
            GroupedBox {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(destination.name).font(TrigType.rowTitle)
                        Text("OSC /trigit/test to \(destination.host):\(destination.port)")
                            .font(TrigType.code).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let result = model.destinationSends[destination.id] { SendStatusBlock(result: result) }
                    Button(model.destinationSends[destination.id]?.ok == false ? "Retry" : "Send Test") {
                        model.testDestination(destination)
                    }
                    .capsuleButton()
                }
                .frame(minHeight: 68)
            }
        } else {
            Footnote("No Destination was added. Add one later in Destinations.")
        }
    }

    private func advance(adding: Bool) {
        if step == 2, adding, let port = UInt16(port) {
            var destination = model.set.destination(destinationID)
                ?? Destination(id: destinationID, name: preset.rawValue, host: host, port: port)
            destination.name = preset.rawValue
            destination.host = host
            destination.port = port
            if preset == .grandMA3 {
                destination[uses: .dmx] = true // Art-Net to the console, as before DMX had its own address
                destination.dmxHost = host
            }
            model.update(destination)
        }
        if step == 3 { dismiss() } else { step += 1 }
    }
}
