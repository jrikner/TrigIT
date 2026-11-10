// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import TrigITEngine

/// The type scale. The readouts are large so the show reads from FOH; the
/// rest are macOS text styles, the size of the controls next to them.
enum TrigType {
    static let playhead = Font.system(size: 128, weight: .bold).monospacedDigit()
    static let songHero = Font.system(size: 60, weight: .bold)
    static let readout = Font.system(size: 60, weight: .bold).monospacedDigit()
    static let simReadout = Font.system(size: 48, weight: .bold).monospacedDigit()
    static let pageTitle = Font.largeTitle.bold()
    static let sectionTitle = Font.title2.bold()
    static let rowTitle = Font.headline
    static let label = Font.body
    static let body = Font.body
    static let secondary = Font.callout
    static let groupHeader = Font.headline
    static let code = Font.body.monospaced()
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

/// Surfaces of the dark window. Each gets stronger with Increase Contrast.
enum Surface {
    static let panel = Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255)
    static let hairline = Color(nsColor: .separatorColor)
    static let selection = tint(0.14)

    /// A white tint over the dark window: fills, tracks, hover.
    static func tint(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let high = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]) != nil
            return NSColor.white.withAlphaComponent(high ? min(1, opacity * 2.5) : opacity)
        })
    }
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

extension View {
    /// A text field that grows with a large font (timecode, a Song's name);
    /// the system rounded-border field keeps a fixed height and clips it.
    func largeField() -> some View { modifier(LargeField()) }
}

private struct LargeField: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Surface.tint(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focused ? Color(nsColor: .keyboardFocusIndicatorColor) : Surface.hairline, lineWidth: focused ? 3 : 1))
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
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Surface.tint(0.05)))
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
        .padding(.vertical, 6)
        .frame(minHeight: 36)
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
    /// A system bordered button.
    func capsuleButton() -> some View { buttonStyle(.bordered) }

    /// The default action button (Restore, Continue).
    func prominentCapsuleButton() -> some View { buttonStyle(.borderedProminent) }

}

/// The + and − under a list, as in Finder and System Settings.
struct AddRemoveButtons: View {
    let add: String
    let remove: String
    let canRemove: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onAdd) { Image(systemName: "plus").frame(width: 24, height: 22).contentShape(Rectangle()) }
                .help(add).accessibilityLabel(add)
            Button(action: onRemove) { Image(systemName: "minus").frame(width: 24, height: 22).contentShape(Rectangle()) }
                .help(remove).accessibilityLabel(remove)
                .disabled(!canRemove)
        }
        .buttonStyle(.borderless)
    }
}

extension ToolbarContent {
    /// The Arm, Show Lock and status pills draw their own fill. In a macOS 26
    /// toolbar, glass behind them would add a second outline, and a system
    /// prominent button there turns grey whenever TrigIT isn't the active app,
    /// which Armed must never do.
    @ToolbarContentBuilder func withoutToolbarGlass() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// A state pill in the toolbar: filled in its colour when on, a hairline
/// capsule when off. It stays coloured when the window isn't active.
private struct StatePill: View {
    let title: String
    let symbol: String
    let fill: Color?
    /// White on red; black on orange, where white is too faint.
    var onFill: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.title3.weight(.semibold))
                .padding(.vertical, 5)
                .padding(.horizontal, 14)
                .foregroundColor(fill == nil ? .primary : onFill)
                .background(Capsule().fill(fill ?? Surface.tint(0.10)))
                .overlay(Capsule().strokeBorder(fill == nil ? Surface.hairline : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Arm and disarm: red while Armed. ⇧⌘A in the Show menu.
struct ArmButton: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        StatePill(title: model.isArmed ? "Armed" : "Disarmed", symbol: model.isArmed ? "bolt.fill" : "bolt.slash",
                  fill: model.isArmed ? StateColor.alert : nil) { model.setArmed(!model.isArmed) }
            .help(model.isArmed ? "Disarm (⇧⌘A): timecode is still followed, nothing is sent"
                                : "Arm (⇧⌘A): Songs send their Actions when entered")
            .accessibilityValue(model.isArmed ? "Armed" : "Disarmed")
    }
}

/// Show Lock: orange while on. ⇧⌘L in the Show menu.
struct ShowLockButton: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        StatePill(title: "Show Lock", symbol: model.isShowLocked ? "lock.fill" : "lock.open",
                  fill: model.isShowLocked ? StateColor.caution : nil, onFill: .black) { model.setShowLocked(!model.isShowLocked) }
            .accessibilityAddTraits(model.isShowLocked ? .isSelected : [])
            .help("Make the Set read-only during the show (⇧⌘L). Arming and the Simulator still work.")
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

extension DestinationStatus {
    var color: Color {
        switch self {
        case .online: return StateColor.ok
        case .offline: return StateColor.alert
        case .unknown, .sent: return StateColor.idle
        }
    }

    /// Worded for what it proves: a send proves nothing, a ping only that the
    /// host is there, an OSC reply that the app is answering.
    var word: String {
        switch self {
        case .unknown: return "Idle"
        case .sent: return "Sent, no answer yet"
        case .online(.responding): return "Responding"
        case .online(.hostAnswers): return "Reachable"
        case .online(.midiOutputConnected): return "MIDI output connected"
        case .offline: return "No reply"
        }
    }
}

/// Minutes and seconds, like 2:53.
func minutesSeconds(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", total / 60, total % 60)
}
