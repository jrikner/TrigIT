// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TrigITEngine

/// A Set as grandMA3 pool-object XML (issue #110): a Sequence with one cue
/// per moment, a Timecode Show that plays it, and a macro that imports both,
/// so the console fires the Set with no TrigIT plugin.
///
/// The cue rules are the MA3 plugin's Import Show, ported from
/// ma3-plugin/src/trigit_plan.lua, commands.lua and ma3.lua. Keep them in step:
/// MA3ExportTests compares these cues with the ones the Lua code writes to
/// ma3-plugin/spec/fixtures/ma3-cues.json. The XML follows what onPC 2.5.1
/// exported for a plugin-made show (Tests/TrigITStorageTests/Fixtures/ma3).
public enum MA3Export {
    /// One cue: what the Timecode Show fires at `seconds` from 00:00:00:00.
    public struct Cue: Equatable, Sendable {
        public var seconds: Double
        public var name: String
        public var command: String
    }

    public struct Options: Equatable, Sendable {
        public var sequence: Int
        public var timecode: Int
        public var macro: Int
        /// The console's timecode slot the Timecode Show follows.
        public var slot: Int
        /// The incoming timecode's: it decides when Stop Actions fire.
        public var frameRate: FrameRate
        /// The In & Out OSC line number for each OSC Destination, by name.
        public var oscLines: [String: Int]

        public init(sequence: Int, timecode: Int, macro: Int, slot: Int, frameRate: FrameRate, oscLines: [String: Int]) {
            self.sequence = sequence
            self.timecode = timecode
            self.macro = macro
            self.slot = slot
            self.frameRate = frameRate
            self.oscLines = oscLines
        }
    }

    /// The note both objects carry. The same as the plugin's, so the plugin's
    /// Import Show replaces them and its panel finds the frame rate.
    static let mark = "Made by the TrigIT plugin. Importing a Set again replaces it."

    // MARK: Cues (trigit_plan.lua, commands.lua, ma3.lua)

    /// The names of the Destinations OSC cues send to, in Set order: each
    /// needs an In & Out OSC line on the console.
    public static func oscDestinations(in set: ShowSet) -> [String] {
        let used = Swift.Set(plan(set, frameRate: .fps30).events.compactMap(\.oscDestination))
        var names: [String] = []
        for destination in set.destinations where used.contains(destination.name) && !names.contains(destination.name) {
            names.append(destination.name)
        }
        return names
    }

    /// The cues, in time order, and why any Song or Action was left out.
    /// Events at the same moment share a cue, their commands joined with "; ";
    /// a MIDI Note Off or DMX release is its own moment. OSC to a Destination
    /// with no line in `oscLines` is left out.
    public static func cues(for set: ShowSet, frameRate: FrameRate, oscLines: [String: Int]) -> (cues: [Cue], warnings: [String]) {
        let planned = plan(set, frameRate: frameRate)
        var cues: [Cue] = []
        var byMoment: [String: Int] = [:]
        func add(_ seconds: Double, _ name: String, _ command: String) {
            let key = String(format: "%.4f", seconds)
            if let index = byMoment[key] {
                cues[index].command += "; " + command
            } else {
                byMoment[key] = cues.count
                cues.append(Cue(seconds: seconds, name: name, command: command))
            }
        }
        for event in planned.events {
            var command = event.command
            if let destination = event.oscDestination {
                guard let line = oscLines[destination], let range = command.range(of: lineToken) else { continue }
                command.replaceSubrange(range, with: String(line))
            }
            let at = seconds(event.time, frameRate)
            add(at, "\(event.song) \(event.phase)", command)
            if let release = event.release {
                add(at + release.after, "\(event.song) \(release.name)", release.command)
            }
        }
        // Moments are distinct, so the order is the same as the Lua sort's.
        return (cues.sorted { $0.seconds < $1.seconds }, planned.warnings)
    }

    private static let lineToken = "$line"

    private struct Release { var after: Double, command: String, name: String }

    private struct Event {
        var time: Timecode
        var song: String
        var phase: String
        var oscDestination: String?
        var command: String
        var release: Release?
    }

    private static func plan(_ set: ShowSet, frameRate rate: FrameRate) -> (events: [Event], warnings: [String]) {
        var events: [Event] = []
        var warnings: [String] = []
        var accepted: [Song] = []
        for song in set.songs {
            let where_ = "Song \"\(song.name)\""
            func warn(_ reason: String) { warnings.append("\(where_): \(reason)") }
            let conflict = song.hasSpan && song.start <= song.end
                ? accepted.first { song.start <= $0.end && $0.start <= song.end } : nil
            if !song.hasSpan {
                let notes = song.startNote != nil && song.stopNote != nil ? "a Start Note and a Stop Note"
                    : song.startNote != nil ? "a Start Note" : song.stopNote != nil ? "a Stop Note" : "no trigger"
                warn("skipped: it has \(notes) and no timecode span, so it can't become timecode events")
            } else if song.start > song.end {
                warn("skipped: end is before start")
            } else if let conflict {
                warn("overlaps \"\(conflict.name)\"")
            } else {
                accepted.append(song)
                for time in [song.start, song.end] where time.frames >= rate.nominalFramesPerSecond {
                    warn("\(time) has frame \(time.frames), past the last frame at \(rate.rawValue) fps")
                }
                for (phase, time, actions) in [("start", song.start, song.startActions),
                                               ("stop", nextFrame(song.end, rate), song.stopActions)] {
                    for action in actions {
                        switch command(for: action.message, to: set.destination(action.destinationID)) {
                        case .success(let (command, release)):
                            let osc = action.message.transport == .osc ? set.destination(action.destinationID)?.name : nil
                            events.append(Event(time: time, song: song.name, phase: phase, oscDestination: osc,
                                                command: command, release: release))
                        case .failure(let reason):
                            warn(reason.text)
                        }
                    }
                }
            }
        }
        // Timecode order; Actions keep their list order within one time.
        let sorted = events.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
        return (sorted.map(\.element), warnings)
    }

    private struct Reason: Error { var text: String }

    /// The MA command for one Action and its later release, if any.
    private static func command(for message: Action.Message, to destination: Destination?) -> Result<(String, Release?), Reason> {
        guard let destination else {
            return .failure(Reason(text: "an Action sends to a Destination that isn't in the Set; left out"))
        }
        guard destination[uses: message.transport] else {
            return .failure(Reason(text: "Destination \"\(destination.name)\" has \(message.transport.name) switched off; Action left out"))
        }
        switch message {
        case .msc:
            // SendMIDI only sends notes, control and program changes, never SysEx.
            return .failure(Reason(text: "MIDI Show Control Actions can't be sent from grandMA3 (SendMIDI has no SysEx); left out"))
        case .osc(let osc):
            var tags = "", args: [String] = []
            for argument in osc.arguments {
                switch argument {
                case .int(let value):
                    tags += "i"; args.append(String(value))
                case .float(let value):
                    // As the Lua code formats the number a Set file holds.
                    tags += "f"; args.append(String(format: "%.9g", Double(value.description) ?? Double(value)))
                case .string(let value):
                    if value.contains(",") || value.contains("\"") {
                        return .failure(Reason(text: "the OSC string \(luaQuoted(value)) contains a comma or quote, which SendOSC can't send"))
                    }
                    tags += "s"; args.append(value)
                }
            }
            var body = osc.address + "," + tags
            if !args.isEmpty { body += "," + args.joined(separator: ",") }
            return .success(("SendOSC \(lineToken) \"\(body)\"", nil))
        case .midiNote(let note):
            let send = { (velocity: UInt8) in "SendMIDI \"Note\" \(Int(note.channel) + 1)/\(note.note) \(velocity)" }
            return .success((send(note.velocity), Release(after: 0.1, command: send(0), name: "note off")))
        case .dmxPulse(let pulse):
            // MA3 universes are 1-based; Art-Net port-address u is MA3 universe u + 1.
            let sACN = destination.dmxOutput?.rawValue.hasPrefix("sACN") == true
            let universe = pulse.universe + (sACN ? 0 : 1)
            guard (1...1024).contains(universe) else {
                return .failure(Reason(text: "\(sACN ? "sACN" : "Art-Net") universe \(pulse.universe) would be MA3 universe \(universe); the console has 1-1024"))
            }
            let address = "DMXUniverse \(universe).\(pulse.channel)"
            return .success(("\(address) At Decimal8 \(pulse.value)",
                             Release(after: pulse.duration, command: "Off " + address, name: "DMX release")))
        }
    }

    /// Lua's %q for the characters a Set's strings hold.
    private static func luaQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\\n") + "\""
    }

    /// The frame after `time`, where Stop Actions fire.
    private static func nextFrame(_ time: Timecode, _ rate: FrameRate) -> Timecode {
        var (h, m, s, f) = (time.hours, time.minutes, time.seconds, time.frames + 1)
        if f >= rate.nominalFramesPerSecond { (f, s) = (0, s + 1) }
        if s > 59 { (s, m) = (0, m + 1) }
        if m > 59 { (m, h) = (0, (h + 1) % 24) }
        // Drop-frame skips frames 0 and 1 at each minute except every tenth.
        if rate.isDropFrame, s == 0, f < 2, m % 10 != 0 { f = 2 }
        return Timecode(hours: h, minutes: m, seconds: s, frames: f)!
    }

    /// Seconds from 00:00:00:00, as the Timecode Show's timeline counts.
    static func seconds(_ time: Timecode, _ rate: FrameRate) -> Double {
        if rate.isDropFrame {
            let minutes = time.hours * 60 + time.minutes
            let frames = (minutes * 60 + time.seconds) * 30 + time.frames - 2 * (minutes - minutes / 10)
            return Double(frames) * 1001 / 30000
        }
        return Double(time.hours * 3600 + time.minutes * 60 + time.seconds) + Double(time.frames) / Double(rate.nominalFramesPerSecond)
    }

    // MARK: Files

    public struct File: Equatable, Sendable {
        public var name: String
        public var contents: Data
    }

    /// The file names MA's Import command takes, without ".xml".
    public static func sequenceFile(_ options: Options) -> String { "trigit_seq\(options.sequence)" }
    public static func timecodeFile(_ options: Options) -> String { "trigit_tc\(options.timecode)" }
    public static func macroFile(_ options: Options) -> String { "trigit_macro\(options.macro)" }

    /// The macro's lines: replace the Timecode and Sequence at those numbers.
    public static func macroLines(_ options: Options) -> [String] {
        ["Delete Timecode \(options.timecode) /NoConfirm",
         "Delete Sequence \(options.sequence) /NoConfirm",
         "Import Sequence \(options.sequence) \"\(sequenceFile(options))\" /NoConfirm",
         "Import Timecode \(options.timecode) \"\(timecodeFile(options))\" /NoConfirm"]
    }

    /// The Sequence, Timecode and macro XML and a README, ready to write.
    /// `guid` makes each object's Guid; tests pass a fixed one.
    public static func files(for set: ShowSet, options: Options, guid: () -> String = randomGuid) -> [File] {
        let cues = cues(for: set, frameRate: options.frameRate, oscLines: options.oscLines).cues
        let name = plain("TrigIT " + set.name)
        return [
            File(name: sequenceFile(options) + ".xml", contents: xml(sequenceXML(name: name, cues: cues, guid: guid))),
            File(name: timecodeFile(options) + ".xml",
                 contents: xml(timecodeXML(name: name, cues: cues, options: options, guid: guid))),
            File(name: macroFile(options) + ".xml", contents: xml(macroXML(set: set, options: options, guid: guid))),
            File(name: "README.txt", contents: Data(readme(set: set, options: options, cueCount: cues.count).utf8)),
        ]
    }

    /// 16 random bytes as MA writes a Guid: "36 DF 15 C4 …".
    public static func randomGuid() -> String {
        (0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined(separator: " ")
    }

    /// As the plugin labels: a quote would end a command's string.
    private static func plain(_ text: String) -> String { text.replacingOccurrences(of: "\"", with: "'") }

    private static func attribute(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\r": out += "&#xD;"
            case "\n": out += "&#xA;"
            case "\r\n": out += "&#xD;&#xA;"
            default: out.append(c)
            }
        }
        return out
    }

    /// UTF-8 with a byte order mark, as MA writes it.
    private static func xml(_ body: String) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<GMA3 DataVersion=\"2.5.1.0\">\n"
            + body + "</GMA3>\n").utf8)
    }

    private static let partAttributes = #"AlignRangeX="No" AlignRangeY="No" AlignRangeZ="No" PreserveGridPositions="No" MAgic="No" Mode="0""#

    static func sequenceXML(name: String, cues: [Cue], guid: () -> String) -> String {
        var text = """
                <Sequence Name="\(attribute(name))" Guid="\(guid())" Note="\(attribute(mark))" AutoStart="Yes" AutoStop="Yes" AutoFix="No" AutoStomp="No" SoftLTP="Yes" XFadeReload="No" SwapProtect="No" KillProtect="No" UseExecutorTime="Yes" OffwhenOverridden="Yes" FreezeNShotAtEnd="No" SequMIB="Enabled" AutoPrePos="No" WrapAround="Yes" MasterGoMode="None" SpeedfromRate="No" Tracking="Yes" IncludeLinkLastGo="Yes" RateScale="One" SpeedScale="One" PreferCueAppearance="No" ExecutorDisplayMode="Data and&#xD;Appearance" Action="Pool Default">
                    <Cue Name="OffCue" Release="Yes" Assert="Assert" AllowDuplicates="" TrigType="">
                        <Part Guid="\(guid())" \(partAttributes) Action="Pool Default"/>
                    </Cue>
                    <Cue Name="CueZero" No="  0">
                        <Part Guid="\(guid())" \(partAttributes) Action="Pool Default"/>
                    </Cue>

            """
        for (index, cue) in cues.enumerated() {
            let cueName = attribute(plain(cue.name))
            text += """
                        <Cue Name="\(cueName)" No="\(String(format: "%3d", index + 1))" AllowDuplicates="">
                            <Part Name="\(cueName)" Guid="\(guid())" \(partAttributes) PhaserSync="" Action="Pool Default" PhaserMorph="" Command="\(attribute(cue.command))"/>
                        </Cue>

                """
        }
        return text + "    </Sequence>\n"
    }

    // The Track names its Sequence by number, not by name as MA's own export
    // does: on onPC 2.5.1 a name MA had changed on import ("#2" for a name
    // in use; "&" and "." dropped) left the Track on another Sequence or none.
    static func timecodeXML(name: String, cues: [Cue], options: Options, guid: () -> String) -> String {
        let readout = options.frameRate == .fps24 ? "24 fps" : options.frameRate == .fps25 ? "25 fps" : "30 fps"
        var text = """
                <Timecode Name="\(attribute(name))" Guid="\(guid())" Note="\(attribute(mark + "\rFrame rate: " + options.frameRate.rawValue))" Duration="104d04h26m13.26" LoopCount="0" TCSlot="\(options.slot)" AutoStart="Yes" SwitchOff="Keep Playbacks" TimeDisplayFormat="10d11h23m45" FrameReadout="\(readout)">
                    <TrackGroup Play="" Rec="">
                        <MarkerTrack Name="Marker" Guid="\(guid())"/>
                        <Track Name="\(attribute(name))" Guid="\(guid())" Target="ShowData.DataPools.Default.Sequences.\(options.sequence)" Play="" Rec="">
                            <TimeRange Guid="\(guid())" Duration="To End" Play="" Rec="">
                                <CmdSubTrack>

            """
        for (index, cue) in cues.enumerated() {
            // The cue by its address: pool 6 (sequences), sequence index, cue number × 1000.
            let destination = "0.6.\(options.sequence - 1).\((index + 1) * 1000)"
            text += """
                                        <CmdEvent Name="Goto" Time="\(time(cue.seconds))" CueDestination="\(attribute(plain(cue.name)))">
                                            <RealtimeCmd Type="Key" Source="Original" UserProfile="0" Environment="0" User="0" Status="On" IsRealtime="0" IsXFade="0" IgnoreFollow="0" IgnoreCommand="0" Assert="0" IgnoreNetwork="0" FromTriggerNode="0" IgnoreExecTime="0" IssuedByTimecode="0" IgnoreExecXFade="0" IsExecXFade="0" ExecToken="Goto" ValCueDestination="\(destination)"/>
                                        </CmdEvent>

                """
        }
        return text + """
                                </CmdSubTrack>
                            </TimeRange>
                        </Track>
                    </TrackGroup>
                </Timecode>

            """
    }

    /// "1h04m00.033", as MA writes an event's Time.
    static func time(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%dh%02dm%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    static func macroXML(set: ShowSet, options: Options, guid: () -> String) -> String {
        let note = "Made by TrigIT from the Set \"\(set.name)\": replaces Timecode \(options.timecode) and Sequence \(options.sequence) with the Set's Timecode Show."
        var text = "    <Macro Name=\"\(attribute(plain("TrigIT " + set.name)))\" Guid=\"\(guid())\" Note=\"\(attribute(note))\">\n"
        for line in macroLines(options) {
            text += "        <MacroLine Guid=\"\(guid())\" Command=\"\(attribute(line))\"/>\n"
        }
        return text + "    </Macro>\n"
    }

    static func readme(set: ShowSet, options: Options, cueCount: Int) -> String {
        let seq = sequenceFile(options), tc = timecodeFile(options), macro = macroFile(options)
        var text = """
            TrigIT: "\(set.name)" as a grandMA3 Timecode Show
            ================================================

            These files make Timecode \(options.timecode) and Sequence \(options.sequence) on a grandMA3 (2.5 or later), with no TrigIT plugin:
            \(cueCount) cue\(cueCount == 1 ? "" : "s"), at \(options.frameRate.rawValue) fps, following timecode slot \(options.slot).

            The macro DELETES Timecode \(options.timecode) and Sequence \(options.sequence) first, whatever they hold.
            Export again with other numbers if those are in use. The Sequence must be at \(options.sequence): the Timecode's events point at its cues by number.

            1. Copy the files into the console's library:
                 \(seq).xml    ->  gma3_library/datapools/sequences/
                 \(tc).xml     ->  gma3_library/datapools/timecodes/
                 \(macro).xml  ->  gma3_library/datapools/macros/
               On onPC for Mac the library is ~/MALightingTechnology/gma3_library. On a console, use a USB stick with
               the same gma3_library/datapools folders and select that drive when importing.

            2. Import the macro. On the command line:
                 Import Macro \(options.macro) "\(macro)" /NoConfirm

            3. Run it: Go+ Macro \(options.macro) (or tap it in the Macros pool). It runs:

            """
        for line in macroLines(options) { text += "     " + line + "\n" }
        let oscDestinations = options.oscLines.sorted { $0.value < $1.value || $0.value == $1.value && $0.key < $1.key }
        if !oscDestinations.isEmpty {
            text += """

                4. Set up the OSC lines (Menu > In & Out > OSC). The cues send with SendOSC on these lines:

                """
            for (name, line) in oscDestinations {
                let destination = set.destinations.first { $0.name == name }
                let address = destination.map { " -> \($0.host) port \($0.port)" } ?? ""
                text += "     Line \(line): \(name)\(address)\n"
            }
            text += """
                   For each: Destination IP and Port as above, Send Command on (MA refuses SendOSC without it),
                   Send off (or MA also sends its own playback feedback to the device), Enable Output on,
                   and an Interface (not "None").

                """
        }
        text += """

            Timecode \(options.timecode) starts by itself when timecode arrives on slot \(options.slot) (Auto Start), and each cue
            sends its Actions at its time. Use either this Timecode Show or the TrigIT app or plugin for a Set, not both:
            both fire the same Actions.

            """
        return text
    }
}
