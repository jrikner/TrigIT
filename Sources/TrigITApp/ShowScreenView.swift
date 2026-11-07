import SwiftUI
import TrigITEngine

/// Show mode: glanceable from 1-3 m at FOH. Source, Playhead, current Song
/// and progress on the left, the Set on the right, status along the bottom.
struct ShowScreenView: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Spacer(minLength: 0)
                sourceLine
                Text(model.playhead?.description ?? "--:--:--:--")
                    .font(TrigType.playhead)
                    .tracking(-2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundColor(model.isReceiving || model.source == .simulator ? .primary : .secondary)
                    .accessibilityLabel("Playhead \(model.playhead?.description ?? "none")")
                currentSong
                progress
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 24, leading: 48, bottom: 40, trailing: 40))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            SetPanel()
                .frame(width: 380)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
    }

    private var sourceLine: some View {
        let state = SourceState(model)
        return HStack(spacing: 10) {
            StateDot(color: state.color, size: 12)
            Text(state.title).font(.system(size: 20, weight: .semibold))
            Text(state.detail).font(.system(size: 20)).foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var currentSong: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Current song").font(.system(size: 18)).foregroundColor(.secondary)
            Text(model.currentSong?.name ?? "No Song")
                .font(TrigType.songHero)
                .tracking(-0.8)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .foregroundColor(model.currentSong == nil ? .secondary : .primary)
        }
    }

    @ViewBuilder
    private var progress: some View {
        let progress = model.progress
        let fraction = progress.flatMap { p in p.elapsed.flatMap { e in p.duration.map { $0 > 0 ? e / $0 : 0 } } }
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(StateColor.ok)
                        .frame(width: geometry.size.width * min(max(fraction ?? 0, 0), 1))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack {
                if let elapsed = progress?.elapsed, let duration = progress?.duration {
                    Text("\(minutesSeconds(elapsed)) of \(minutesSeconds(duration))")
                }
                Spacer()
                if let next = progress?.nextSongID.flatMap(model.song), let until = progress?.untilNext {
                    Text("\(next.name) starts in \(minutesSeconds(until))")
                }
            }
            .font(.system(size: 18).monospacedDigit())
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: 820)
    }
}

/// The Set, in order: fired Songs ticked, the current one highlighted.
struct SetPanel: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        FloatingPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Set").font(TrigType.sectionTitle)
                    Text("\(model.set.songs.count) song\(model.set.songs.count == 1 ? "" : "s")")
                        .font(.system(size: 16)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.set.songs) { song in row(song).id(song.id) }
                        }
                    }
                    .onChange(of: model.currentSongID) { id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            .padding(12)
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func row(_ song: Song) -> some View {
        let isCurrent = song.id == model.currentSongID
        let fired = model.firedThisRun.contains(song.id) && !isCurrent
        return HStack(spacing: 10) {
            Group {
                if isCurrent {
                    Image(systemName: "play.fill").accessibilityLabel("Current")
                } else if fired {
                    Image(systemName: "checkmark").accessibilityLabel("Fired")
                } else {
                    Color.clear
                }
            }
            .foregroundColor(StateColor.ok)
            .frame(width: 20)
            Text(song.name)
                .font(.system(size: 21, weight: isCurrent ? .bold : .regular))
                .foregroundColor(fired ? .secondary : .primary)
                .lineLimit(1)
            Spacer()
            Text(song.hasSpan ? String(song.start.description.prefix(8)) : "Start Note")
                .font(.system(size: 16).monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isCurrent ? StateColor.ok.opacity(0.16) : Color.clear))
        .accessibilityElement(children: .combine)
    }
}

/// Primary and Backup Source health, the last firing and the frame rate.
struct StatusBar: View {
    @EnvironmentObject private var model: ShowModel

    var body: some View {
        HStack(spacing: 24) {
            sourceStatus(.primary)
            if model.backupSource != nil { sourceStatus(.backup) }
            Spacer()
            if let firing = model.lastFiringSummary {
                Label(firing.text, systemImage: firing.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(firing.failed ? StateColor.alert : StateColor.ok, .primary)
                    .lineLimit(1)
            }
            Text(model.frameRate.map { "\($0.rawValue) fps" } ?? "-- fps")
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .font(.system(size: 16))
        .padding(.horizontal, 20)
        .frame(height: 48)
        .overlay(alignment: .top) { RowDivider() }
    }

    private func sourceStatus(_ role: SourceRole) -> some View {
        let word = SourceRoleState(model, role)
        let choice = role == .primary ? model.source : model.backupSource
        return HStack(spacing: 8) {
            StateDot(color: word.color, size: 8)
            Text("\(role == .primary ? "Primary" : "Backup") \(choice?.kindName ?? "")")
            Text(word.word).fontWeight(.semibold).foregroundColor(word.color)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Live, Standby or Lost for one source role.
struct SourceRoleState {
    let word: String
    let color: Color

    @MainActor
    init(_ model: ShowModel, _ role: SourceRole) {
        let healthy = model.healthySources.contains(role) || (role == .primary ? model.source : model.backupSource) == .simulator
        if model.liveSource == role {
            word = healthy ? "Live" : "Lost"
            color = healthy ? (role == .backup ? StateColor.caution : StateColor.ok) : StateColor.alert
        } else {
            word = healthy ? "Standby" : "Lost"
            color = healthy ? StateColor.idle : StateColor.alert
        }
    }
}

// MARK: - Simulator

/// Shown in both modes while the Primary or Backup Source is the Simulator.
struct SimulatorPanel: View {
    @EnvironmentObject private var model: ShowModel
    @State private var targetText = "01:00:00:00"

    private var target: Timecode? { Timecode(targetText) }
    private var pads: [Song] { model.set.songs.filter(\.hasSpan) }

    var body: some View {
        FloatingPanel(border: StateColor.caution.opacity(0.55)) {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            StateDot(color: StateColor.caution)
                            Text("Simulator").font(.system(size: 18, weight: .bold))
                        }
                        Text("Replaces live timecode").font(.system(size: 14)).foregroundColor(.secondary)
                    }
                    Button { model.play() } label: {
                        Image(systemName: "play.fill").font(.system(size: 20)).foregroundColor(.black)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color.white.opacity(model.simulator.isPlaying ? 0.4 : 0.9)))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.simulator.isPlaying)
                    .accessibilityLabel("Play")
                    Button { model.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 20))
                            .frame(width: 52, height: 52)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.simulator.isPlaying)
                    .accessibilityLabel("Stop")
                    TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                        Text(model.simulator.position(at: model.now).description)
                            .font(TrigType.simReadout)
                    }
                    Spacer()
                    TextField("Simulator timecode", text: $targetText, prompt: Text("hh:mm:ss:ff"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(TrigType.body.monospacedDigit())
                        .foregroundColor(target == nil ? StateColor.alert : .primary)
                        .frame(width: 130)
                    Button("Play From") { if let target { model.play(from: target) } }
                        .capsuleButton().disabled(target == nil)
                    Button("Jump") { if let target { model.jump(to: target) } }
                        .capsuleButton().disabled(target == nil)
                    Picker("Frame rate", selection: Binding(
                        get: { model.simulator.frameRate },
                        set: { model.setSimulatorFrameRate($0) }
                    )) {
                        ForEach(FrameRate.allCases, id: \.self) { Text("\($0.rawValue) fps").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                .padding(16)
                if !pads.isEmpty {
                    RowDivider()
                    HStack(spacing: 8) {
                        Text("Jump to 5 s before").font(.system(size: 16)).foregroundColor(.secondary)
                            .frame(width: 190, alignment: .leading)
                        ForEach(pads) { song in
                            Button { model.rehearse(song) } label: {
                                Text(song.name).lineLimit(1).frame(maxWidth: .infinity)
                            }
                            .capsuleButton()
                            .help("Jump to 5 seconds before \(song.name) and play")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }
}
