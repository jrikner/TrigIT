// How a Set is written to its file. Hand-written rather than synthesized so
// the JSON reads well (timecodes as "01:00:00:00", Actions tagged by type) and
// so files from older versions still open: any field added later is optional
// when reading and falls back to its default.

import TrigITProtocols

extension EntityID: Codable {
    /// Written as a string: JSON numbers above 2^53 lose precision in many tools.
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = UInt64(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\"\(text)\" is not an ID"))
        }
        self.init(rawValue: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(rawValue))
    }
}

extension Timecode: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let timecode = Timecode(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\"\(text)\" is not a timecode (hh:mm:ss:ff)"))
        }
        self = timecode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension ShowSet: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, stopTime, destinations, songs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(SetID.self, forKey: .id) ?? SetID(),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Set",
            songs: try c.decodeIfPresent([Song].self, forKey: .songs) ?? [],
            destinations: try c.decodeIfPresent([Destination].self, forKey: .destinations) ?? [],
            stopTime: try c.decodeIfPresent(Double.self, forKey: .stopTime) ?? ShowSet.defaultStopTime
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(stopTime, forKey: .stopTime)
        try c.encode(destinations, forKey: .destinations)
        try c.encode(songs, forKey: .songs)
    }
}

extension Song: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, start, end, startNote, stopNote, startActions, stopActions
    }

    /// A Song without "start" has no span. Missing notes decode as none, so
    /// files from before notes existed still open.

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decodeIfPresent(Timecode.self, forKey: .start)
        self.init(
            id: try c.decodeIfPresent(SongID.self, forKey: .id) ?? SongID(),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            start: start ?? .zero,
            end: start == nil ? .zero : try c.decode(Timecode.self, forKey: .end),
            hasSpan: start != nil,
            startNote: try c.decodeIfPresent(NoteTrigger.self, forKey: .startNote),
            stopNote: try c.decodeIfPresent(NoteTrigger.self, forKey: .stopNote),
            startActions: try c.decodeIfPresent([Action].self, forKey: .startActions) ?? [],
            stopActions: try c.decodeIfPresent([Action].self, forKey: .stopActions) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if hasSpan {
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
        }
        try c.encodeIfPresent(startNote, forKey: .startNote)
        try c.encodeIfPresent(stopNote, forKey: .stopNote)
        try c.encode(startActions, forKey: .startActions)
        try c.encode(stopActions, forKey: .stopActions)
    }
}

extension Destination: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, usesOSC, usesMIDI, usesDMX, host, port, networkInterface, midiOutput, replyPort
        case dmxOutput, dmxHost, dmxInterface, sacnPriority, dmxSourceName, dmxRefreshRate
    }

    /// Files from before the on/off switches load as they behaved: OSC on,
    /// MIDI and DMX on if their output is set. Files from before DMX had its
    /// own address and interface use the OSC ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        let networkInterface = try c.decodeIfPresent(String.self, forKey: .networkInterface)
        self.init(
            id: try c.decodeIfPresent(DestinationID.self, forKey: .id) ?? DestinationID(),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            host: host,
            port: try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 0,
            networkInterface: networkInterface,
            midiOutput: try c.decodeIfPresent(MIDIPortReference.self, forKey: .midiOutput),
            dmxOutput: try c.decodeIfPresent(DMXOutput.self, forKey: .dmxOutput),
            replyPort: try c.decodeIfPresent(UInt16.self, forKey: .replyPort),
            usesOSC: try c.decodeIfPresent(Bool.self, forKey: .usesOSC) ?? true,
            usesMIDI: try c.decodeIfPresent(Bool.self, forKey: .usesMIDI),
            usesDMX: try c.decodeIfPresent(Bool.self, forKey: .usesDMX),
            dmxHost: try c.decodeIfPresent(String.self, forKey: .dmxHost) ?? host,
            // Written as null for "Automatic", so a missing key means an older file.
            dmxInterface: c.contains(.dmxInterface) ? try c.decodeIfPresent(String.self, forKey: .dmxInterface) : networkInterface,
            sacnPriority: try c.decodeIfPresent(UInt8.self, forKey: .sacnPriority) ?? SACNDataPacket.defaultPriority,
            dmxSourceName: try c.decodeIfPresent(String.self, forKey: .dmxSourceName) ?? Destination.defaultDMXSourceName,
            dmxRefreshRate: try c.decodeIfPresent(Double.self, forKey: .dmxRefreshRate) ?? Destination.defaultDMXRefreshRate
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(usesOSC, forKey: .usesOSC)
        try c.encode(usesMIDI, forKey: .usesMIDI)
        try c.encode(usesDMX, forKey: .usesDMX)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encodeIfPresent(networkInterface, forKey: .networkInterface)
        try c.encodeIfPresent(midiOutput, forKey: .midiOutput)
        try c.encodeIfPresent(dmxOutput, forKey: .dmxOutput)
        try c.encode(dmxHost, forKey: .dmxHost)
        try c.encode(dmxInterface, forKey: .dmxInterface)
        try c.encode(sacnPriority, forKey: .sacnPriority)
        try c.encode(dmxSourceName, forKey: .dmxSourceName)
        try c.encode(dmxRefreshRate, forKey: .dmxRefreshRate)
        try c.encodeIfPresent(replyPort, forKey: .replyPort)
    }
}

extension Action: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, destination, type, osc, midiNote, msc, dmxPulse
    }

    private enum Kind: String, Codable {
        case osc, midiNote, msc, dmxPulse
    }

    /// `{"id", "destination", "type": "osc", "osc": {...}}`: the message sits
    /// under a key named after its type.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let message: Message
        switch try c.decode(Kind.self, forKey: .type) {
        case .osc: message = .osc(try c.decode(OSCMessage.self, forKey: .osc))
        case .midiNote: message = .midiNote(try c.decode(MIDINote.self, forKey: .midiNote))
        case .msc: message = .msc(try c.decode(MSCCommand.self, forKey: .msc))
        case .dmxPulse: message = .dmxPulse(try c.decode(DMXPulse.self, forKey: .dmxPulse))
        }
        self.init(
            id: try c.decodeIfPresent(ActionID.self, forKey: .id) ?? ActionID(),
            destinationID: try c.decode(DestinationID.self, forKey: .destination),
            message: message
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(destinationID, forKey: .destination)
        switch message {
        case .osc(let osc):
            try c.encode(Kind.osc, forKey: .type)
            try c.encode(osc, forKey: .osc)
        case .midiNote(let note):
            try c.encode(Kind.midiNote, forKey: .type)
            try c.encode(note, forKey: .midiNote)
        case .msc(let command):
            try c.encode(Kind.msc, forKey: .type)
            try c.encode(command, forKey: .msc)
        case .dmxPulse(let pulse):
            try c.encode(Kind.dmxPulse, forKey: .type)
            try c.encode(pulse, forKey: .dmxPulse)
        }
    }
}
