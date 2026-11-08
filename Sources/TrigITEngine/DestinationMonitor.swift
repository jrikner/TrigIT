/// Whether a Destination is reachable right now, and what proves it. A send
/// alone never proves anything: UDP accepts a datagram for any routable
/// address, connected or not.
public enum DestinationStatus: Hashable, Sendable {
    /// Nothing sent or heard yet, and no check has failed.
    case unknown
    /// A send went out and nothing has answered yet.
    case sent
    case online(OnlineEvidence)
    case offline(OfflineReason)

    public var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }

    /// Higher is worse; a Destination shows its worst transport.
    fileprivate var severity: Int {
        switch self {
        case .online: return 0
        case .sent: return 1
        case .unknown: return 2
        case .offline: return 3
        }
    }
}

/// What showed a Destination is there, strongest first.
public enum OnlineEvidence: Hashable, Sendable {
    /// An OSC reply arrived on its reply port: the receiving app is running.
    case responding
    /// Its address answered a ping: the host is there, maybe not the app.
    case hostAnswers
    /// Its MIDI output exists.
    case midiOutputConnected
}

public enum OfflineReason: Hashable, Sendable {
    /// The network interface the Destination sends through is gone.
    case interfaceMissing(String)
    /// The Destination's MIDI output (a port or network MIDI session) is gone.
    case midiOutputMissing(String)
    /// Pings went unanswered and no OSC reply came for `DestinationMonitor.timeout`.
    case notResponding
    /// The last send failed, with the reason.
    case sendFailed(String)
}

/// A Destination's status changed.
public struct DestinationStatusChange: Hashable, Sendable {
    public let destinationID: DestinationID
    public let name: String
    public let old: DestinationStatus
    public let new: DestinationStatus

    public init(destinationID: DestinationID, name: String, old: DestinationStatus, new: DestinationStatus) {
        self.destinationID = destinationID
        self.name = name
        self.old = old
        self.new = new
    }
}

/// An address the app pings, and the interface to ping it through.
public struct PingTarget: Hashable, Sendable {
    public let host: String
    public let networkInterface: String?

    public init(host: String, networkInterface: String?) {
        self.host = host
        self.networkInterface = networkInterface
    }
}

/// Decides each Destination's status from the checks the app runs (pings,
/// OSC replies, which network interfaces and MIDI outputs exist) and the
/// results of its sends. Each transport a Destination uses gets a status,
/// and the Destination shows the worst. No I/O; the app reports what it saw
/// and asks for the statuses at a time.
public struct DestinationMonitor: Sendable {
    /// How often the app pings each Destination, in seconds.
    public static let pingInterval = 2.0
    /// How long a ping answer or OSC reply counts as proof of being online.
    /// Longer than two ping intervals, so one lost ping doesn't flap the status.
    public static let timeout = 5.0

    private struct PingKey: Hashable, Sendable {
        let id: DestinationID
        let host: String
    }

    private struct SendKey: Hashable, Sendable {
        let id: DestinationID
        let transport: Transport
    }

    public private(set) var statuses: [DestinationID: DestinationStatus] = [:]
    private var answered: [PingKey: Double] = [:]
    private var failed: [PingKey: Double] = [:]
    private var replied: [DestinationID: Double] = [:]
    private var lastSend: [SendKey: (time: Double, error: String?)] = [:]

    public init() {}

    /// Whether an address can be pinged. Broadcast and multicast addresses
    /// (Art-Net to 2.255.255.255, sACN groups) don't answer pings.
    public static func isPingable(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 != nil }) else { return true } // a host name
        return octets[3] != 255 && !(224...239).contains(octets[0]!)
    }

    /// The address and interface a network transport sends to, if it has one.
    static func address(of destination: Destination, for transport: Transport) -> PingTarget? {
        switch transport {
        case .osc: return PingTarget(host: destination.host, networkInterface: destination.networkInterface)
        case .midi: return nil
        case .dmx:
            let host = destination.activeDMXOutput == .sACNMulticast ? "" : destination.dmxHost
            return PingTarget(host: host, networkInterface: destination.dmxInterface)
        }
    }

    /// What the app should ping for the Destination: the pingable address of
    /// each network transport it uses, once each.
    public static func pingTargets(of destination: Destination) -> [PingTarget] {
        var targets: [PingTarget] = []
        for transport in destination.transports {
            if let target = address(of: destination, for: transport), isPingable(target.host), !targets.contains(target) {
                targets.append(target)
            }
        }
        return targets
    }

    public mutating func pingAnswered(_ id: DestinationID, host: String, at time: Double) {
        let key = PingKey(id: id, host: host)
        answered[key] = max(answered[key] ?? time, time)
    }

    public mutating func pingFailed(_ id: DestinationID, host: String, at time: Double) {
        let key = PingKey(id: id, host: host)
        failed[key] = max(failed[key] ?? time, time)
    }

    /// An OSC datagram arrived on a reply port. It belongs to the Destination
    /// with that reply port and that address, or to the only Destination with
    /// that reply port (a host name won't match the sender's address).
    public mutating func replyReceived(onPort port: UInt16, from address: String, in set: ShowSet, at time: Double) {
        let candidates = set.destinations.filter { $0.usesOSC && $0.replyPort == port }
        let matches = candidates.filter { $0.host == address }
        for destination in matches.isEmpty && candidates.count == 1 ? candidates : matches {
            replied[destination.id] = max(replied[destination.id] ?? time, time)
        }
    }

    /// A send over `transport` finished: `error` is nil if it went out. A
    /// failed send shows until a later send over the same transport succeeds.
    public mutating func sendFinished(_ id: DestinationID, over transport: Transport, error: String?, at time: Double) {
        lastSend[SendKey(id: id, transport: transport)] = (time, error)
    }

    /// Recomputes every Destination's status and returns the ones that changed.
    /// - Parameters:
    ///   - interfaces: BSD names of the network interfaces present, or nil while not yet known.
    ///   - midiOutputs: unique IDs of the MIDI outputs present.
    public mutating func update(_ set: ShowSet, interfaces: Swift.Set<String>?, midiOutputs: Swift.Set<Int32>,
                                at now: Double) -> [DestinationStatusChange] {
        var changes: [DestinationStatusChange] = []
        var newStatuses: [DestinationID: DestinationStatus] = [:]
        for destination in set.destinations {
            let new = status(of: destination, interfaces: interfaces, midiOutputs: midiOutputs, at: now)
            let old = statuses[destination.id] ?? .unknown
            newStatuses[destination.id] = new
            if new != old {
                changes.append(DestinationStatusChange(destinationID: destination.id, name: destination.name, old: old, new: new))
            }
        }
        statuses = newStatuses
        let ids = Swift.Set(newStatuses.keys)
        answered = answered.filter { ids.contains($0.key.id) }
        failed = failed.filter { ids.contains($0.key.id) }
        replied = replied.filter { ids.contains($0.key) }
        lastSend = lastSend.filter { ids.contains($0.key.id) }
        return changes
    }

    /// The worst of its transports' statuses. A network transport that can't
    /// be checked (a broadcast address and no reply port) and hasn't sent
    /// yet says nothing, so it doesn't hold a MIDI Destination at unknown.
    private func status(of destination: Destination, interfaces: Swift.Set<String>?, midiOutputs: Swift.Set<Int32>,
                        at now: Double) -> DestinationStatus {
        var worst: DestinationStatus?
        for transport in destination.transports {
            let status = self.status(of: destination, over: transport, interfaces: interfaces, midiOutputs: midiOutputs, at: now)
            if status == .unknown, !canCheck(destination, over: transport) { continue }
            if worst == nil || status.severity > worst!.severity { worst = status }
        }
        return worst ?? .unknown
    }

    private func canCheck(_ destination: Destination, over transport: Transport) -> Bool {
        switch transport {
        case .midi: return true
        case .osc: return destination.replyPort != nil || Self.isPingable(destination.host)
        case .dmx: return Self.address(of: destination, for: .dmx).map { Self.isPingable($0.host) } ?? false
        }
    }

    private func status(of destination: Destination, over transport: Transport, interfaces: Swift.Set<String>?,
                        midiOutputs: Swift.Set<Int32>, at now: Double) -> DestinationStatus {
        let send = lastSend[SendKey(id: destination.id, transport: transport)]
        if let error = send?.error { return .offline(.sendFailed(error)) }

        guard let address = Self.address(of: destination, for: transport) else {
            guard let output = destination.activeMIDIOutput else { return .unknown }
            return midiOutputs.contains(output.uniqueID) ? .online(.midiOutputConnected) : .offline(.midiOutputMissing(output.name))
        }
        if let interface = address.networkInterface, let interfaces, !interfaces.contains(interface) {
            return .offline(.interfaceMissing(interface))
        }
        let key = PingKey(id: destination.id, host: address.host)
        let reply = transport == .osc ? replied[destination.id] : nil
        if let reply, now - reply <= Self.timeout { return .online(.responding) }
        let heard = [answered[key], reply].compactMap { $0 }.max()
        if let ping = answered[key], now - ping <= Self.timeout { return .online(.hostAnswers) }
        if let failure = failed[key], failure > (heard ?? -.infinity) { return .offline(.notResponding) }
        return send != nil ? .sent : .unknown
    }
}
