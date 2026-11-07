import XCTest
import TrigITEngine
import TrigITProtocols

/// Each preset fills in the ordinary OSC or MSC message Resolume or grandMA3 documents.
final class PresetTests: XCTestCase {
    private func osc(_ address: String, _ arguments: OSCArgument...) -> Action.Message {
        .osc(OSCMessage(address: address, arguments: arguments))
    }

    func testResolumePresets() {
        XCTAssertEqual(ActionPreset.resolumeLaunchColumn(column: 3).message, osc("/composition/columns/3/connect", .int(1)))
        XCTAssertEqual(ActionPreset.resolumeLaunchClip(layer: 2, column: 5).message,
                       osc("/composition/layers/2/clips/5/connect", .int(1)))
        XCTAssertEqual(ActionPreset.resolumeClearLayer(layer: 4).message, osc("/composition/layers/4/clear", .int(1)))
        XCTAssertEqual(ActionPreset.resolumeClearComposition.message, osc("/composition/disconnectall", .int(1)))
        XCTAssertEqual(ActionPreset.resolumeNextColumn.message, osc("/composition/connectnextcolumn", .int(1)))
        XCTAssertEqual(ActionPreset.resolumePreviousColumn.message, osc("/composition/connectprevcolumn", .int(1)))
        XCTAssertEqual(ActionPreset.resolumeTempoResync.message, osc("/composition/tempocontroller/resync", .int(1)))
    }

    func testMA3OSCPresets() {
        XCTAssertEqual(ActionPreset.ma3GoExecutor(page: 1, executor: 201).message, osc("/cmd", .string("Go+ Exec 1.201")))
        XCTAssertEqual(ActionPreset.ma3Command("Macro 5").message, osc("/cmd", .string("Macro 5")))
    }

    func testMA3GoCueIsMSCGo() {
        let message = ActionPreset.ma3GoCue(cue: "12.5", list: "3").message
        XCTAssertEqual(message, .msc(MSCCommand(command: .go, cue: "12.5", list: "3")))
        guard case .msc(let command) = message else { return XCTFail() }
        XCTAssertTrue(command.isValid)
    }

    func testEveryOSCPresetHasAValidAddress() {
        let presets: [ActionPreset] = [.resolumeLaunchColumn(column: 1), .resolumeLaunchClip(layer: 1, column: 1),
                                       .resolumeClearLayer(layer: 1), .resolumeClearComposition, .resolumeNextColumn,
                                       .resolumePreviousColumn, .resolumeTempoResync,
                                       .ma3GoExecutor(page: 1, executor: 101), .ma3Command("Go+")]
        for preset in presets {
            guard case .osc(let message) = preset.message else { return XCTFail("\(preset)") }
            XCTAssertTrue(message.hasValidAddress, "\(preset)")
        }
    }
}
