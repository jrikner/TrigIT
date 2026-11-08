// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
import CoreMIDI
import Foundation

/// A MIDI source TrigIT can listen to: a physical port, a network MIDI
/// session, or an internal (IAC) bus.
struct MIDISourceInfo: Hashable, Identifiable {
    /// Core MIDI's unique ID; stays the same across launches.
    let uniqueID: MIDIUniqueID
    let name: String
    var id: MIDIUniqueID { uniqueID }
}

/// Listens to one MIDI source through Core MIDI and delivers its raw bytes.
final class MIDIInput {
    /// Called on the main queue with each packet's bytes and its monotonic
    /// time in seconds (same clock as `ProcessInfo.systemUptime`).
    var onBytes: (([UInt8], Double) -> Void)?
    /// Called on the main queue when sources appear or disappear.
    var onSourcesChanged: (() -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: MIDIEndpointRef?
    private(set) var startError: OSStatus?

    init() {
        var status = MIDIClientCreateWithBlock("TrigIT" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.onSourcesChanged?() }
            }
        }
        guard status == noErr else { startError = status; return }
        status = MIDIInputPortCreateWithBlock(client, "TrigIT input" as CFString, &port) { [weak self] packets, _ in
            self?.read(packets)
        }
        if status != noErr { startError = status }
    }

    deinit {
        disconnect()
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func sources() -> [MIDISourceInfo] {
        (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }
            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
            return MIDISourceInfo(uniqueID: uniqueID, name: Self.displayName(endpoint))
        }
    }

    /// Listens to the source with this unique ID; returns false if it isn't present.
    @discardableResult
    func connect(to uniqueID: MIDIUniqueID) -> Bool {
        disconnect()
        guard port != 0 else { return false }
        var object = MIDIObjectRef()
        var type = MIDIObjectType.source
        guard MIDIObjectFindByUniqueID(uniqueID, &object, &type) == noErr, type == .source,
              MIDIPortConnectSource(port, object, nil) == noErr else { return false }
        connected = object
        return true
    }

    func disconnect() {
        if let connected { MIDIPortDisconnectSource(port, connected) }
        connected = nil
    }

    /// Runs on Core MIDI's thread.
    private func read(_ packets: UnsafePointer<MIDIPacketList>) {
        var batch: [([UInt8], Double)] = []
        for packet in packets.unsafeSequence() {
            let length = Int(packet.pointee.length)
            // Read through a raw pointer: a packet can be longer than the
            // fixed-size `data` tuple in the struct definition.
            let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
            let start = UnsafeRawPointer(packet).advanced(by: dataOffset)
            let bytes = Array(UnsafeRawBufferPointer(start: start, count: length))
            let hostTime = packet.pointee.timeStamp
            let time = hostTime == 0
                ? ProcessInfo.processInfo.systemUptime
                : Double(AudioConvertHostTimeToNanos(hostTime)) / 1_000_000_000
            batch.append((bytes, time))
        }
        DispatchQueue.main.async { [weak self] in
            for (bytes, time) in batch { self?.onBytes?(bytes, time) }
        }
    }

    private static func displayName(_ endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr, let name else {
            return "MIDI source"
        }
        return name.takeRetainedValue() as String
    }
}
