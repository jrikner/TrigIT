/// Values for one DMX universe: slots 1...512, stored 0-based.
public let dmxSlotCount = 512

/// A pulse on one DMX channel: the value for `duration` seconds, then 0.
public struct DMXPulse: Hashable, Sendable, Codable {
    /// Art-Net port-address (0...32767) or sACN universe (1...63999),
    /// depending on the Destination.
    public var universe: Int
    /// 1...512.
    public var channel: Int
    public var value: UInt8
    /// Seconds the value is held.
    public var duration: Double

    public static let defaultValue: UInt8 = 255
    public static let defaultDuration = 0.5
    public static let durationRange = 0.05...10.0

    public init(universe: Int, channel: Int, value: UInt8 = DMXPulse.defaultValue, duration: Double = DMXPulse.defaultDuration) {
        self.universe = universe
        self.channel = min(max(channel, 1), dmxSlotCount)
        self.value = value
        self.duration = min(max(duration, Self.durationRange.lowerBound), Self.durationRange.upperBound)
    }

    public var summary: String {
        "Pulse universe \(universe) channel \(channel) = \(value) for \(Int((duration * 1000).rounded())) ms"
    }
}

// MARK: - Art-Net

/// An Art-Net 4 ArtDmx packet: "Art-Net\0", OpCode 0x5000 (low byte first),
/// protocol version 14, Sequence, Physical, SubUni, Net, Length (high byte
/// first), then the slot data.
public struct ArtDmxPacket: Hashable, Sendable {
    /// 15-bit port-address: Net (7 bits), Sub-Net (4 bits), Universe (4 bits).
    public static let portAddressRange = 0...32_767

    public var portAddress: Int
    /// 1...255; 0 tells receivers not to reorder.
    public var sequence: UInt8
    public var physical: UInt8 = 0
    /// Up to 512 slots; padded to an even length of at least 2 when sent.
    public var data: [UInt8]

    public init(portAddress: Int, sequence: UInt8, data: [UInt8]) {
        self.portAddress = portAddress
        self.sequence = sequence
        self.data = data
    }

    public var encoded: [UInt8] {
        var slots = Array(data.prefix(dmxSlotCount))
        while slots.count < 2 || slots.count % 2 != 0 { slots.append(0) }
        let address = UInt16(clamping: portAddress) & 0x7FFF
        return Array("Art-Net".utf8) + [0x00, 0x00, 0x50, 0x00, 14, sequence, physical,
                                       UInt8(address & 0xFF), UInt8(address >> 8),
                                       UInt8(slots.count >> 8), UInt8(slots.count & 0xFF)] + slots
    }
}

// MARK: - sACN

/// An ANSI E1.31 (sACN) data packet: root layer, framing layer, DMP layer.
public struct SACNDataPacket: Hashable, Sendable {
    public static let port: UInt16 = 5568
    public static let universeRange = 1...63_999
    public static let defaultPriority: UInt8 = 100

    /// The sender's 16-byte component identifier (CID), the same for every packet.
    public var cid: [UInt8]
    public var sourceName: String
    public var universe: Int
    public var priority: UInt8
    public var sequence: UInt8
    /// Up to 512 slots, after the null start code.
    public var data: [UInt8]

    public init(cid: [UInt8], sourceName: String, universe: Int, priority: UInt8 = SACNDataPacket.defaultPriority,
                sequence: UInt8, data: [UInt8]) {
        self.cid = cid
        self.sourceName = sourceName
        self.universe = universe
        self.priority = priority
        self.sequence = sequence
        self.data = data
    }

    /// The multicast group for a universe: 239.255.<high byte>.<low byte>.
    public static func multicastAddress(universe: Int) -> String {
        let value = UInt16(clamping: universe)
        return "239.255.\(value >> 8).\(value & 0xFF)"
    }

    public var encoded: [UInt8] {
        let slots = Array(data.prefix(dmxSlotCount))
        let total = 126 + slots.count
        var bytes: [UInt8] = []
        bytes.reserveCapacity(total)

        // Root layer.
        bytes += [0x00, 0x10, 0x00, 0x00]
        bytes += Array("ASC-E1.17".utf8) + [0, 0, 0]
        bytes += Self.flagsAndLength(total - 16)
        bytes += [0x00, 0x00, 0x00, 0x04] // VECTOR_ROOT_E131_DATA
        bytes += Array((cid + [UInt8](repeating: 0, count: 16)).prefix(16))

        // Framing layer.
        bytes += Self.flagsAndLength(total - 38)
        bytes += [0x00, 0x00, 0x00, 0x02] // VECTOR_E131_DATA_PACKET
        var name = Array(sourceName.utf8.prefix(63))
        name += [UInt8](repeating: 0, count: 64 - name.count)
        bytes += name
        bytes.append(min(priority, 200))
        bytes += [0x00, 0x00] // synchronization address: none
        bytes.append(sequence)
        bytes.append(0x00) // options
        let universe = UInt16(clamping: self.universe)
        bytes += [UInt8(universe >> 8), UInt8(universe & 0xFF)]

        // DMP layer.
        bytes += Self.flagsAndLength(total - 115)
        bytes += [0x02, 0xA1, 0x00, 0x00, 0x00, 0x01] // set property, address/data type, first address, increment
        let count = UInt16(slots.count + 1)
        bytes += [UInt8(count >> 8), UInt8(count & 0xFF)]
        bytes.append(0x00) // DMX512 null start code
        bytes += slots
        return bytes
    }

    private static func flagsAndLength(_ length: Int) -> [UInt8] {
        let value = 0x7000 | UInt16(length & 0x0FFF)
        return [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
}

// MARK: - Pulse mixing

/// Holds the pulses running in each universe and works out the universe's
/// slot values at any moment. Pulses on different channels never affect each
/// other; overlapping pulses on the same channel take the highest value
/// (highest takes precedence). Pure: callers pass in the time.
public struct DMXPulseMixer<Universe: Hashable & Sendable>: Sendable {
    private struct Running: Sendable {
        let channel: Int
        let value: UInt8
        let until: Double
    }

    private var running: [Universe: [Running]] = [:]

    public init() {}

    /// Starts a pulse at `time`.
    public mutating func start(_ pulse: DMXPulse, in universe: Universe, at time: Double) {
        running[universe, default: []].append(Running(channel: pulse.channel, value: pulse.value, until: time + pulse.duration))
    }

    /// The universe's 512 slot values at `time`, forgetting pulses that have ended.
    public mutating func levels(_ universe: Universe, at time: Double) -> [UInt8] {
        var slots = [UInt8](repeating: 0, count: dmxSlotCount)
        guard var pulses = running[universe] else { return slots }
        pulses.removeAll { $0.until <= time }
        running[universe] = pulses.isEmpty ? nil : pulses
        for pulse in pulses {
            slots[pulse.channel - 1] = max(slots[pulse.channel - 1], pulse.value)
        }
        return slots
    }

    /// When the next pulse ends, so its release can be sent without waiting
    /// for the next refresh.
    public func nextEnd(after time: Double) -> Double? {
        running.values.joined().map(\.until).filter { $0 > time }.min()
    }
}
