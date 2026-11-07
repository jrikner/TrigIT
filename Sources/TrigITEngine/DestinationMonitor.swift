/// Whether a Destination is reachable right now.
public enum DestinationStatus: Hashable, Sendable {
    /// Nothing heard yet, and no check has failed.
    case unknown
    case online
    case offline(OfflineReason)

    public var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }
}

public enum OfflineReason: Hashable, Sendable {
    /// The network interface the Destination sends through is gone.
    case interfaceMissing(String)
    /// The Destination's MIDI output (a port or network MIDI session) is gone.
    case midiOutputMissing(String)
    /// Pings went unanswered and no OSC reply came for `DestinationMonitor.timeout`.
    case notResponding
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

/// Decides each Destination's status from the checks the app runs: pings,
/// OSC replies, which network interfaces and MIDI outputs exist. No I/O; the
/// app reports what it saw and asks for the statuses at a time.
public struct DestinationMonitor: Sendable {
    /// How often the app pings each Destination, in seconds.
    public static let pingInterval = 2.0
    /// How long a ping answer or OSC reply counts as proof of being online.
    /// Longer than two ping intervals, so one lost ping doesn't flap the status.
    public static let timeout = 5.0

    public private(set) var statuses: [DestinationID: DestinationStatus] = [:]
    private var lastHeard: [DestinationID: Double] = [:]
    private var lastFailure: [DestinationID: Double] = [:]

    public init() {}

    /// Whether the app should ping the Destination. Broadcast and multicast
    /// addresses (Art-Net to 2.255.255.255, sACN groups) don't answer pings.
    public static func shouldPing(_ destination: Destination) -> Bool {
        let host = destination.host
        guard !host.isEmpty else { return false }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 != nil }) else { return true } // a host name
        return octets[3] != 255 && !(224...239).contains(octets[0]!)
    }

    public mutating func pingAnswered(_ id: DestinationID, at time: Double) {
        lastHeard[id] = max(lastHeard[id] ?? time, time)
    }

    public mutating func pingFailed(_ id: DestinationID, at time: Double) {
        lastFailure[id] = max(lastFailure[id] ?? time, time)
    }

    /// An OSC datagram arrived on a reply port. It belongs to the Destination
    /// with that reply port and that address, or to the only Destination with
    /// that reply port (a host name won't match the sender's address).
    public mutating func replyReceived(onPort port: UInt16, from address: String, in set: ShowSet, at time: Double) {
        let candidates = set.destinations.filter { $0.replyPort == port }
        let matches = candidates.filter { $0.host == address }
        for destination in matches.isEmpty && candidates.count == 1 ? candidates : matches {
            pingAnswered(destination.id, at: time)
        }
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
        lastHeard = lastHeard.filter { ids.contains($0.key) }
        lastFailure = lastFailure.filter { ids.contains($0.key) }
        return changes
    }

    private func status(of destination: Destination, interfaces: Swift.Set<String>?, midiOutputs: Swift.Set<Int32>,
                        at now: Double) -> DestinationStatus {
        if let interface = destination.networkInterface, let interfaces, !interfaces.contains(interface) {
            return .offline(.interfaceMissing(interface))
        }
        if let output = destination.midiOutput, !midiOutputs.contains(output.uniqueID) {
            return .offline(.midiOutputMissing(output.name))
        }
        let heard = lastHeard[destination.id]
        if let heard, now - heard <= Self.timeout { return .online }
        if let failure = lastFailure[destination.id], failure > (heard ?? -.infinity) {
            return .offline(.notResponding)
        }
        return destination.midiOutput != nil ? .online : .unknown
    }
}
