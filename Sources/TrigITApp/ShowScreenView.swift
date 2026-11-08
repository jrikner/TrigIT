// SPDX-License-Identifier: GPL-3.0-or-later

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
                PlayheadText()
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

/// The big Playhead. Green: rolling inside a Song. Orange: rolling between
/// Songs. Flashing red: timecode stopped or was lost after rolling (no flash
/// with Reduce Motion). Gray: no timecode yet. While disarmed and rolling it
/// pulses slowly in its green or orange, with "Disarmed" beside it.
struct PlayheadText: View {
    @EnvironmentObject private var model: ShowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    private enum PlayheadState { case inSong, betweenSongs, stopped, none }

    private var state: PlayheadState {
        guard let playhead = model.playhead else { return .none }
        guard model.isReceiving, model.alert == nil else { return .stopped }
        return model.set.songs.contains { $0.contains(playhead) } ? .inSong : .betweenSongs
    }

    /// Rolling, but nothing is sent.
    private var rollingDisarmed: Bool {
        !model.isArmed && (state == .inSong || state == .betweenSongs)
    }

    /// Which animation runs: the Stopped flash, the slower disarmed pulse, or none.
    private enum Pulse { case stopped, disarmed }

    private var pulse: Pulse? {
        state == .stopped ? .stopped : rollingDisarmed ? .disarmed : nil
    }

    var body: some View {
        let state = state
        let pulse = pulse
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(model.playhead?.description ?? "00:00:00:00")
                .font(TrigType.playhead)
                .tracking(-2)
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .foregroundColor(color(state))
                .opacity(dim ? (pulse == .stopped ? 0.35 : 0.6) : 1)
            if rollingDisarmed {
                Label("Disarmed", systemImage: "bolt.slash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.secondary)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playhead \(model.playhead?.description ?? "none")")
        .accessibilityValue(rollingDisarmed ? "\(word(state)), disarmed" : word(state))
        .onChange(of: pulse) { animate($0) }
        .onAppear { animate(pulse) }
    }

    private func animate(_ pulse: Pulse?) {
        withAnimation(nil) { dim = false }
        guard let pulse, !reduceMotion else { return }
        // The disarmed pulse is slower and shallower than the Stopped flash.
        // Start on the next turn, so a running pulse of the other kind stops first.
        let duration = pulse == .stopped ? 0.5 : 1.2
        DispatchQueue.main.async {
            guard self.pulse == pulse else { return }
            withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) { dim = true }
        }
    }

    private func color(_ state: PlayheadState) -> Color {
        switch state {
        case .inSong: return StateColor.ok
        case .betweenSongs: return StateColor.caution
        case .stopped: return StateColor.alert
        case .none: return .secondary
        }
    }

    private func word(_ state: PlayheadState) -> String {
        switch state {
        case .inSong: return "Rolling in a Song"
        case .betweenSongs: return "Rolling between Songs"
        case .stopped: return "Stopped"
        case .none: return "No timecode"
        }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func row(_ song: Song) -> some View {
        let isCurrent = song.id == model.currentSongID
        // Current, but entered while disarmed: nothing was sent, so not playing.
        let unsent = isCurrent && song.id == model.unsentSongID
        let isPlaying = isCurrent && !unsent
        let fired = model.firedThisRun.contains(song.id) && !isCurrent
        return HStack(spacing: 10) {
            Group {
                if isPlaying {
                    Image(systemName: "play.fill").accessibilityLabel("Current")
                } else if unsent {
                    Image(systemName: "bolt.slash").foregroundColor(.secondary).accessibilityLabel("Current")
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
            if unsent {
                Text(model.isArmed ? "Not sent" : "Disarmed")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Text(song.hasSpan ? song.start.description : "Start Note")
                .font(.system(size: 16).monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isPlaying ? StateColor.ok.opacity(0.16) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(unsent ? Color.secondary.opacity(0.6) : Color.clear, lineWidth: 1.5))
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
                Label(firing.text, systemImage: firing.failed == true ? "xmark.circle.fill"
                      : firing.failed == false ? "checkmark.circle.fill" : "bolt.slash")
                    .foregroundStyle(firing.failed == true ? StateColor.alert : firing.failed == false ? StateColor.ok : StateColor.idle,
                                     .primary)
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
        if (role == .primary ? model.source : model.backupSource) == .simulator, !model.simulator.isPlaying {
            word = "Stopped"
            color = StateColor.idle
        } else if model.liveSource == role {
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
                        .textFieldStyle(TrigFieldStyle())
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
