import AppKit
import SwiftUI

/// The type scale: larger than macOS defaults, so the show reads from FOH.
enum TrigType {
    static let playhead = Font.system(size: 128, weight: .bold).monospacedDigit()
    static let songHero = Font.system(size: 60, weight: .bold)
    static let readout = Font.system(size: 60, weight: .bold).monospacedDigit()
    static let simReadout = Font.system(size: 48, weight: .bold).monospacedDigit()
    static let pageTitle = Font.system(size: 32, weight: .bold)
    static let sectionTitle = Font.system(size: 22, weight: .bold)
    static let rowTitle = Font.system(size: 18, weight: .semibold)
    static let label = Font.system(size: 18)
    static let body = Font.system(size: 17)
    static let secondary = Font.system(size: 15)
    static let groupHeader = Font.system(size: 15, weight: .semibold)
    static let code = Font.system(size: 15, design: .monospaced)
}

/// Colour only ever means state, and always comes with a word or symbol.
enum StateColor {
    /// Armed, Failed, No signal, No reply.
    static let alert = Color(nsColor: .systemRed)
    /// Receiving, Fired, Sent, Reachable, Live.
    static let ok = Color(nsColor: .systemGreen)
    /// Dropout, Show Lock, Simulator, Backup live, Failover.
    static let caution = Color(nsColor: .systemOrange)
    /// Stopped, Disarmed, Standby, Idle.
    static let idle = Color(nsColor: .systemGray)
}

/// Surfaces of the dark window.
enum Surface {
    static let panel = Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255)
    static let hairline = Color.white.opacity(0.08)
    static let selection = Color.primary.opacity(0.14)
}

/// Show mode is glanceable from FOH; Edit mode has the sidebar.
enum AppMode: String {
    case show, edit
}

/// The Edit mode sidebar sections.
enum EditSection: String, CaseIterable, Identifiable {
    case songs = "Songs", destinations = "Destinations", timecode = "Timecode", fireLog = "Fire Log"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .songs: return "list.bullet"
        case .destinations: return "dot.radiowaves.left.and.right"
        case .timecode: return "clock"
        case .fireLog: return "doc.text"
        }
    }
}

/// The app icon, for the welcome and opening screens and the Dock.
enum AppIcon {
    static let image: NSImage = {
        // In the app bundle: the icon actool compiled from Resources/AppIcon.icon.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            return image
        }
        // Run with `swift run`: there is no bundle, so use the PNG exported from it.
        let png = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/AppIcon.png").standardizedFileURL
        return NSImage(contentsOf: png) ?? NSApp.applicationIconImage
    }()
}

/// Text fields that grow with their font, so large timecode is never clipped
/// (the system rounded-border field keeps a fixed height).
struct TrigFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// A small filled circle in a state colour, always next to a word.
struct StateDot: View {
    let color: Color
    var size: CGFloat = 10

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// The floating rounded panel used for the Set list, Simulator and Open Recent.
struct FloatingPanel<Content: View>: View {
    var border: Color = Surface.hairline
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Surface.panel))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(border, lineWidth: 1))
    }
}

/// A sentence-case header above a grouped box, with optional trailing content.
struct GroupHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(TrigType.groupHeader).foregroundColor(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
    }
}

extension GroupHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// A grouped box of rows, as in System Settings: white 5% fill, 8% border.
/// Put a `RowDivider` between rows.
struct GroupedBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Surface.hairline, lineWidth: 1))
    }
}

/// The hairline between rows of a `GroupedBox`.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Surface.hairline).frame(height: 1)
    }
}

/// One row of a `GroupedBox`: a label on the left, controls on the right.
struct FormRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(TrigType.label)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }
}

/// A secondary footnote below a group.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(TrigType.secondary)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

extension View {
    /// The standard large capsule button.
    func capsuleButton() -> some View { buttonStyle(CapsuleButtonStyle(prominent: false)) }

    /// The default action button (Restore, Continue).
    func prominentCapsuleButton() -> some View { buttonStyle(CapsuleButtonStyle(prominent: true)) }
}

/// A 17 pt capsule button, sized for the show (system bordered buttons stay small).
struct CapsuleButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TrigType.body)
            .lineLimit(1)
            .padding(.vertical, 7)
            .padding(.horizontal, 16)
            .foregroundColor(prominent ? .black : .primary)
            .background(Capsule().fill(prominent
                ? Color.white.opacity(configuration.isPressed ? 0.7 : 0.88)
                : Color.white.opacity(configuration.isPressed ? 0.22 : 0.12)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// Arm and disarm. Armed: red fill, white bolt and word. Disarmed: bordered.
struct ArmButton: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        Button {
            model.setArmed(!model.isArmed)
        } label: {
            Label(model.isArmed ? "Armed" : "Disarmed", systemImage: model.isArmed ? "bolt.fill" : "bolt.slash")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 18, weight: model.isArmed ? .bold : .semibold))
                .padding(.vertical, 6)
                .padding(.horizontal, 18)
                .foregroundColor(model.isArmed ? .white : .primary)
                .background(Capsule().fill(model.isArmed ? StateColor.alert : Color.primary.opacity(0.10)))
                .overlay(Capsule().strokeBorder(model.isArmed ? Color.clear : Surface.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .help(model.isArmed ? "Disarm (⇧⌘A): timecode is still followed, nothing is sent"
                            : "Arm (⇧⌘A): Songs send their Actions when entered")
        .accessibilityValue(model.isArmed ? "Armed" : "Disarmed")
    }
}

/// Show Lock: orange fill and lock when on, bordered when off.
struct ShowLockButton: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        Button {
            model.setShowLocked(!model.isShowLocked)
        } label: {
            Label("Show Lock", systemImage: model.isShowLocked ? "lock.fill" : "lock.open")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 16, weight: .semibold))
                .padding(.vertical, 6)
                .padding(.horizontal, 16)
                .foregroundColor(model.isShowLocked ? .black : .primary)
                .background(Capsule().fill(model.isShowLocked ? StateColor.caution : Color.primary.opacity(0.10)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.isShowLocked ? .isSelected : [])
        .help("Make the Set read-only during the show. Arming and the Simulator still work.")
    }
}

/// A "Sent"/"Failed" block: symbol and word over a short note.
struct SendStatusBlock: View {
    let result: ShowModel.SendResult

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Label(result.ok ? "Sent" : "Failed", systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(result.ok ? StateColor.ok : StateColor.alert)
            Text(result.ok ? "at \(result.timecode?.description ?? result.date.formatted(date: .omitted, time: .standard))"
                           : (result.errorText ?? "Not sent"))
                .font(.system(size: 14).monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: 220, alignment: .trailing)
        .help(result.errorText ?? "")
    }
}

extension ShowModel.Reachability {
    var color: Color {
        switch self {
        case .reachable: return StateColor.ok
        case .noReply: return StateColor.alert
        case .idle: return StateColor.idle
        }
    }

    var word: String {
        switch self {
        case .reachable: return "Reachable"
        case .noReply: return "No reply"
        case .idle: return "Idle"
        }
    }
}

/// Minutes and seconds, like 2:53.
func minutesSeconds(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}
