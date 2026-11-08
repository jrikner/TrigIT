// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreMIDI
import Foundation
import TrigITEngine
import TrigITProtocols

/// A MIDI output TrigIT can send to: a physical port, a network MIDI session
/// or an internal (IAC) bus.
struct MIDIOutputInfo: Hashable, Identifiable {
    let uniqueID: MIDIUniqueID
    let name: String
    var id: MIDIUniqueID { uniqueID }

    var reference: MIDIPortReference { MIDIPortReference(uniqueID: uniqueID, name: name) }
}

/// Sends MIDI through Core MIDI. Every Note On gets its Note Off: after
/// `noteLength`, or at once when TrigIT disarms or quits.
final class MIDIOutput {
    enum SendError: LocalizedError {
        case unavailable(OSStatus)
        case portMissing(String)
        case failed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unavailable(let status): return "MIDI is unavailable (error \(status))"
            case .portMissing(let name): return "MIDI output \(name) is not connected"
            case .failed(let status): return "MIDI send failed (error \(status))"
            }
        }
    }

    /// How long a triggered note is held before its Note Off.
    static let noteLength: TimeInterval = 0.1

    /// Called on the main queue when outputs appear or disappear.
    var onOutputsChanged: (() -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var setupError: OSStatus?

    private struct HeldNote: Hashable {
        let output: MIDIUniqueID
        let note: MIDINote
    }
    /// Notes whose Note Off is still to come. Main queue only.
    private var heldNotes: [HeldNote: DispatchWorkItem] = [:]
    private var terminationObserver: NSObjectProtocol?

    init() {
        var status = MIDIClientCreateWithBlock("TrigIT output" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.onOutputsChanged?() }
            }
        }
        if status == noErr {
            status = MIDIOutputPortCreate(client, "TrigIT output" as CFString, &port)
        }
        if status != noErr { setupError = status }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.releaseAllNotes() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func outputs() -> [MIDIOutputInfo] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }
            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
            var name: Unmanaged<CFString>?
            let found = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr
            return MIDIOutputInfo(uniqueID: uniqueID, name: found ? (name!.takeRetainedValue() as String) : "MIDI output")
        }
    }

    /// Sends Note On now and Note Off after `noteLength`. A repeat of a note
    /// still held restarts its length rather than stacking Note Offs.
    func play(_ note: MIDINote, on output: MIDIPortReference) throws {
        let held = HeldNote(output: output.uniqueID, note: note)
        heldNotes.removeValue(forKey: held)?.cancel()
        try send(note.noteOn, to: output)
        let release = DispatchWorkItem { [weak self] in
            guard let self, self.heldNotes.removeValue(forKey: held) != nil else { return }
            try? self.send(note.noteOff, to: output)
        }
        heldNotes[held] = release
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteLength, execute: release)
    }

    /// Sends every pending Note Off immediately.
    func releaseAllNotes() {
        let notes = heldNotes
        heldNotes.removeAll()
        for (held, release) in notes {
            release.cancel()
            try? send(held.note.noteOff, to: MIDIPortReference(uniqueID: held.output, name: ""))
        }
    }

    /// Sends one complete MIDI message (or SysEx) to the output.
    func send(_ bytes: [UInt8], to output: MIDIPortReference) throws {
        if let setupError { throw SendError.unavailable(setupError) }
        var object = MIDIObjectRef()
        var type = MIDIObjectType.destination
        guard MIDIObjectFindByUniqueID(output.uniqueID, &object, &type) == noErr, type == .destination else {
            throw SendError.portMissing(output.name)
        }
        let bufferSize = 1_024
        var status: OSStatus = noErr
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        buffer.withUnsafeMutableBytes { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            let packet = MIDIPacketListInit(list)
            guard MIDIPacketListAdd(list, bufferSize, packet, 0, bytes.count, bytes) != nil else {
                status = -1
                return
            }
            status = MIDISend(port, object, list)
        }
        guard status == noErr else { throw SendError.failed(status) }
    }
}
