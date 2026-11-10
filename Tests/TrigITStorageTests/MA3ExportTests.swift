// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
import TrigITEngine
import TrigITProtocols
import TrigITStorage

final class MA3ExportTests: XCTestCase {
    private static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let pluginFixtures = tests.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ma3-plugin/spec/fixtures")

    /// The same cues and warnings as the plugin's Lua code, which writes
    /// ma3-cues.json from the same Set files (spec/ma3_spec.lua).
    func testCuesMatchThePlugin() throws {
        struct Case: Decodable {
            struct Cue: Decodable { var seconds: Double, name: String, command: String }
            var file: String, frameRate: String, oscLines: [String: Int], cues: [Cue], warnings: [String]
        }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: Self.pluginFixtures.appendingPathComponent("ma3-cues.json")))
        XCTAssertEqual(cases.count, 4)
        for expected in cases {
            let set = try SetFile.read(from: Self.pluginFixtures.appendingPathComponent(expected.file))
            let result = MA3Export.cues(for: set, frameRate: try XCTUnwrap(FrameRate(rawValue: expected.frameRate)), oscLines: expected.oscLines)
            let label = "\(expected.file) at \(expected.frameRate)"
            XCTAssertEqual(result.warnings, expected.warnings, label)
            XCTAssertEqual(result.cues.map(\.name), expected.cues.map(\.name), label)
            XCTAssertEqual(result.cues.map(\.command), expected.cues.map(\.command), label)
            XCTAssertEqual(result.cues.count, expected.cues.count, label)
            for (cue, want) in zip(result.cues, expected.cues) {
                XCTAssertEqual(cue.seconds, want.seconds, accuracy: 1e-6, "\(label): \(cue.name)")
            }
        }
    }

    func testWarnsAsThePluginDoes() {
        let osc = Destination(name: "Resolume", host: "127.0.0.1", port: 7000)
        let off = Destination(name: "Off", host: "127.0.0.1", port: 7000, usesOSC: false)
        let dmx = Destination(name: "Lights", host: "", port: 0, dmxOutput: .artNet)
        let set = ShowSet(songs: [
            Song(name: "A", start: Timecode("00:00:01:00")!, end: Timecode("00:00:02:29")!, startActions: [
                Action(destinationID: osc.id, message: .osc(OSCMessage(address: "/a", arguments: [.string("x, \"y\"")]))),
                Action(destinationID: off.id, message: .osc(OSCMessage(address: "/b", arguments: []))),
                Action(destinationID: DestinationID(), message: .osc(OSCMessage(address: "/c", arguments: []))),
                Action(destinationID: dmx.id, message: .dmxPulse(DMXPulse(universe: 1024, channel: 1))),
            ]),
            Song(name: "B", start: Timecode("00:00:05:00")!, end: Timecode("00:00:04:00")!),
        ], destinations: [osc, off, dmx])
        XCTAssertEqual(MA3Export.cues(for: set, frameRate: .fps25, oscLines: [:]).warnings, [
            #"Song "A": 00:00:02:29 has frame 29, past the last frame at 25 fps"#,
            #"Song "A": the OSC string "x, \"y\"" contains a comma or quote, which SendOSC can't send"#,
            #"Song "A": Destination "Off" has OSC switched off; Action left out"#,
            #"Song "A": an Action sends to a Destination that isn't in the Set; left out"#,
            #"Song "A": Art-Net universe 1024 would be MA3 universe 1025; the console has 1-1024"#,
            #"Song "B": skipped: end is before start"#,
        ])
    }

    func testStopActionsFireAfterADropFrameMinute() {
        let osc = Destination(name: "R", host: "127.0.0.1", port: 7000)
        let set = ShowSet(songs: [
            Song(name: "A", start: Timecode("00:00:00:00")!, end: Timecode("00:00:59:29")!,
                 stopActions: [Action(destinationID: osc.id, message: .osc(OSCMessage(address: "/x", arguments: [.float(0.1)])))]),
        ], destinations: [osc])
        let cues = MA3Export.cues(for: set, frameRate: .fps2997DropFrame, oscLines: ["R": 4]).cues
        // 00:00:59:29 is followed by 00:01:00:02, frame 1800.
        XCTAssertEqual(cues.map(\.command), [#"SendOSC 4 "/x,f,0.1""#])
        XCTAssertEqual(cues[0].seconds, 1800 * 1001 / 30000, accuracy: 1e-9)
    }

    /// The XML for the example Set (with a Stop Action added, as on onPC) is
    /// what onPC 2.5.1 exported for the same show made by the plugin, apart
    /// from the Guids, which MA makes up.
    func testXMLMatchesWhatMAExported() throws {
        var set = ShowSet.example
        let resolume = set.destinations[0].id
        set.songs[0].stopActions = [Action(destinationID: resolume, message: .osc(OSCMessage(address: "/test/stop", arguments: [])))]
        let options = MA3Export.Options(sequence: 110, timecode: 110, macro: 1, slot: 1, frameRate: .fps30, oscLines: ["Resolume": 1])
        XCTAssertEqual(MA3Export.oscDestinations(in: set), ["Resolume"])
        let files = MA3Export.files(for: set, options: options)
        XCTAssertEqual(files.map(\.name), ["trigit_seq110.xml", "trigit_tc110.xml", "trigit_macro1.xml", "README.txt"])

        for (file, reference) in zip(files.prefix(2), ["trigit_seq110.xml", "trigit_tc110.xml"]) {
            let expected = try Data(contentsOf: Self.tests.appendingPathComponent("Fixtures/ma3/\(reference)"))
            XCTAssertEqual(Array(file.contents.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 with a byte order mark")
            // MA's export names the Track's Sequence; ours numbers it (see timecodeXML).
            let expectedText = withoutGuids(expected)
                .replacingOccurrences(of: "Sequences.TrigIT Example Set\"", with: "Sequences.110\"")
            XCTAssertEqual(withoutGuids(file.contents), expectedText, reference)
        }

        let macro = String(decoding: files[2].contents.dropFirst(3), as: UTF8.self)
        XCTAssertEqual(withoutGuids(files[2].contents), """
            <?xml version="1.0" encoding="UTF-8"?>
            <GMA3 DataVersion="2.5.1.0">
                <Macro Name="TrigIT Example Set" Guid="" Note="Made by TrigIT from the Set &quot;Example Set&quot;: replaces Timecode 110 and Sequence 110 with the Set's Timecode Show.">
                    <MacroLine Guid="" Command="Delete Timecode 110 /NoConfirm"/>
                    <MacroLine Guid="" Command="Delete Sequence 110 /NoConfirm"/>
                    <MacroLine Guid="" Command="Import Sequence 110 &quot;trigit_seq110&quot; /NoConfirm"/>
                    <MacroLine Guid="" Command="Import Timecode 110 &quot;trigit_tc110&quot; /NoConfirm"/>
                </Macro>
            </GMA3>

            """)
        XCTAssertNotNil(macro.range(of: #"Guid="([0-9A-F]{2} ){15}[0-9A-F]{2}""#, options: .regularExpression), "MA's Guid format")
        let readme = String(decoding: files[3].contents, as: UTF8.self)
        XCTAssertTrue(readme.contains(#"Import Macro 1 "trigit_macro1" /NoConfirm"#))
        XCTAssertTrue(readme.contains("Line 1: Resolume -> 127.0.0.1 port 7000"))
    }

    func testCueNumbersAndAddressesFollowTheSequenceNumber() {
        let osc = Destination(name: "R", host: "127.0.0.1", port: 7000)
        let songs = (0..<12).map { i in
            Song(name: "S\(i)", start: Timecode(hours: 1, minutes: i, seconds: 0, frames: 0)!, end: Timecode(hours: 1, minutes: i, seconds: 30, frames: 0)!,
                 startActions: [Action(destinationID: osc.id, message: .osc(OSCMessage(address: "/s\(i)", arguments: [])))])
        }
        let options = MA3Export.Options(sequence: 7, timecode: 3, macro: 2, slot: 4, frameRate: .fps25, oscLines: ["R": 2])
        let files = MA3Export.files(for: ShowSet(name: "Big", songs: songs, destinations: [osc]), options: options) { "G" }
        let sequence = String(decoding: files[0].contents, as: UTF8.self)
        let timecode = String(decoding: files[1].contents, as: UTF8.self)
        XCTAssertTrue(sequence.contains(#"<Cue Name="S11 start" No=" 12" AllowDuplicates="">"#))
        XCTAssertTrue(timecode.contains(#"Time="1h11m00.000" CueDestination="S11 start""#))
        XCTAssertTrue(timecode.contains(#"ValCueDestination="0.6.6.12000""#))
        XCTAssertTrue(timecode.contains(#"TCSlot="4""#))
        XCTAssertTrue(timecode.contains(#"FrameReadout="25 fps""#))
        XCTAssertTrue(timecode.contains("Frame rate: 25"))
    }

    private func withoutGuids(_ data: Data) -> String {
        String(decoding: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, as: UTF8.self)
            .replacingOccurrences(of: #"Guid="[^"]*""#, with: #"Guid="""#, options: .regularExpression)
    }
}
