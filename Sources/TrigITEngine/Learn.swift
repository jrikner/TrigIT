import TrigITProtocols

/// Learn: program by example. The app listens on the chosen MIDI inputs and
/// an OSC port; the first message one of these accepts is what gets learned.
public enum Learn {
    /// Learn stops listening on its own after this many seconds.
    public static let timeout = 30.0

    /// The Action message a captured MIDI message becomes: a Note On becomes
    /// a MIDI note Action with its channel, note and velocity; an MSC GO, STOP
    /// or RESUME becomes an MSC Action. Anything else (Note Off, MTC) is ignored.
    public static func actionMessage(from midi: MIDIMessage) -> Action.Message? {
        switch midi {
        case .noteOn(let channel, let note, let velocity):
            return .midiNote(MIDINote(channel: channel, note: note, velocity: velocity))
        case .systemExclusive(let bytes):
            return MSCCommand(sysEx: bytes).map { .msc($0) }
        case .noteOff, .quarterFrame:
            return nil
        }
    }

    /// The Action message a captured OSC packet becomes: the same address and
    /// arguments, or nil if the packet isn't an OSC message TrigIT can send.
    public static func actionMessage(fromOSC packet: [UInt8]) -> Action.Message? {
        OSCMessage(decoding: packet).map { .osc($0) }
    }

    /// The Start or Stop Note a captured MIDI message sets: a Note On's channel
    /// and note number. Anything else is ignored.
    public static func noteTrigger(from midi: MIDIMessage) -> NoteTrigger? {
        guard case .noteOn(let channel, let note, _) = midi else { return nil }
        return NoteTrigger(channel: channel, note: note)
    }
}
