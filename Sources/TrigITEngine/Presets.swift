import TrigITProtocols

/// A common Resolume or grandMA3 command. A preset only fills in an ordinary
/// OSC or MSC message, which stays editable; nothing remembers the preset.
///
/// Resolume addresses follow Resolume 7's OSC list
/// (https://resolume.com/support/en/osc); each trigger is sent as int 1.
/// grandMA3 commands use its "/cmd" command-line address
/// (https://help.malighting.com/grandMA3/2.3/HTML/remote_inputs_osc.html), which
/// needs Receive Command on the console's OSC line; if that line has a prefix,
/// edit the address to start with it (for example "/gma3/cmd").
public enum ActionPreset: Hashable, Sendable {
    case resolumeLaunchColumn(column: Int)
    case resolumeLaunchClip(layer: Int, column: Int)
    case resolumeClearLayer(layer: Int)
    case resolumeClearComposition
    case resolumeNextColumn
    case resolumePreviousColumn
    case resolumeTempoResync
    /// Go+ on executor `executor` of page `page`, over OSC.
    case ma3GoExecutor(page: Int, executor: Int)
    /// Any grandMA3 command-line text, over OSC.
    case ma3Command(String)
    /// MSC GO for cue `cue` in cue list `list` (grandMA3: the executor; empty for the selected one).
    case ma3GoCue(cue: String, list: String)

    public var message: Action.Message {
        switch self {
        case .resolumeLaunchColumn(let column): return Self.resolume("/composition/columns/\(column)/connect")
        case .resolumeLaunchClip(let layer, let column): return Self.resolume("/composition/layers/\(layer)/clips/\(column)/connect")
        case .resolumeClearLayer(let layer): return Self.resolume("/composition/layers/\(layer)/clear")
        case .resolumeClearComposition: return Self.resolume("/composition/disconnectall")
        case .resolumeNextColumn: return Self.resolume("/composition/connectnextcolumn")
        case .resolumePreviousColumn: return Self.resolume("/composition/connectprevcolumn")
        case .resolumeTempoResync: return Self.resolume("/composition/tempocontroller/resync")
        case .ma3GoExecutor(let page, let executor): return Self.ma3("Go+ Exec \(page).\(executor)")
        case .ma3Command(let text): return Self.ma3(text)
        case .ma3GoCue(let cue, let list): return .msc(MSCCommand(command: .go, cue: cue, list: list))
        }
    }

    private static func resolume(_ address: String) -> Action.Message {
        .osc(OSCMessage(address: address, arguments: [.int(1)]))
    }

    private static func ma3(_ command: String) -> Action.Message {
        .osc(OSCMessage(address: "/cmd", arguments: [.string(command)]))
    }
}
