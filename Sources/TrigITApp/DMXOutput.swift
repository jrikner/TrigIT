import Darwin
import Foundation
import TrigITEngine
import TrigITProtocols

/// Sends UDP datagrams for Art-Net and sACN through BSD sockets, which (unlike
/// Network.framework) can broadcast, choose the multicast interface, and be
/// locked to one interface with IP_BOUND_IF. One socket per interface.
final class DMXSocketSender {
    enum SendError: LocalizedError, Equatable {
        case notAnIPv4Address(String)
        case unknownInterface(String)
        case socket(call: String, reason: String)

        static func failed(_ call: String) -> SendError {
            .socket(call: call, reason: String(cString: strerror(errno)))
        }

        var errorDescription: String? {
            switch self {
            case .notAnIPv4Address(let host): return "\"\(host)\" is not an IPv4 address"
            case .unknownInterface(let name): return "network interface \(name) is not available"
            case .socket(let call, let reason): return "\(call) failed: \(reason)"
            }
        }
    }

    private var sockets: [String: Int32] = [:]

    deinit { sockets.values.forEach { close($0) } }

    func send(_ bytes: [UInt8], to host: String, port: UInt16, interface: String?) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw SendError.notAnIPv4Address(host) }
        let fd = try socket(for: interface)
        let sent = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == bytes.count else {
            let error = SendError.failed("sendto")
            // The interface may have gone away; open a fresh socket next time.
            close(fd)
            sockets[interface ?? ""] = nil
            throw error
        }
    }

    private func socket(for interface: String?) throws -> Int32 {
        let key = interface ?? ""
        if let existing = sockets[key] { return existing }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SendError.failed("socket") }
        var keep = false
        defer { if !keep { close(fd) } }

        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SendError.failed("SO_BROADCAST")
        }
        if let interface {
            var index = if_nametoindex(interface)
            guard index != 0 else { throw SendError.unknownInterface(interface) }
            let size = socklen_t(MemoryLayout<UInt32>.size)
            guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, size) == 0 else { throw SendError.failed("IP_BOUND_IF") }
            // Multicast (sACN) leaves through the same interface.
            guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IFINDEX, &index, size) == 0 else {
                throw SendError.failed("IP_MULTICAST_IFINDEX")
            }
        }
        sockets[key] = fd
        keep = true
        return fd
    }
}

/// Streams every universe the Set's pulse Actions use, from launch until quit,
/// and plays pulses into them. Each universe is refreshed at its Destination's
/// refresh rate (zeros at rest), and a pulse's start and end are sent at once
/// rather than waiting for the next refresh.
@MainActor
final class DMXStreamer {
    struct UniverseKey: Hashable, Sendable {
        let destination: DestinationID
        let universe: Int
    }

    /// How often the streamer looks for universes due a refresh.
    private static let tick = 0.005

    /// Reports a problem with a universe once, until it sends successfully again.
    var onError: ((String) -> Void)?

    private let sender = DMXSocketSender()
    private var mixer = DMXPulseMixer<UniverseKey>()
    private var streams: [UniverseKey: Destination] = [:]
    private var sequences: [UniverseKey: UInt8] = [:]
    private var lastSent: [UniverseKey: Double] = [:]
    private var failing: Set<UniverseKey> = []
    private var timer: Timer?
    private let cid = DMXStreamer.componentID()

    init() {
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Streams exactly the universes the Set uses on Destinations with a DMX output.
    func update(for set: ShowSet) {
        var next: [UniverseKey: Destination] = [:]
        for (id, universes) in set.dmxUniversesInUse {
            guard let destination = set.destination(id), destination.activeDMXOutput != nil else { continue }
            for universe in universes {
                next[UniverseKey(destination: id, universe: universe)] = destination
            }
        }
        streams = next
        failing.formIntersection(next.keys)
        lastSent = lastSent.filter { next[$0.key] != nil }
    }

    /// Starts a pulse now. Throws if the Destination can't take it.
    func play(_ pulse: DMXPulse, to destination: Destination) throws {
        guard let output = destination.activeDMXOutput else { throw PulseError.noDMXOutput(destination.name) }
        guard output.universeRange.contains(pulse.universe) else {
            throw PulseError.universeOutOfRange(pulse.universe, output)
        }
        let key = UniverseKey(destination: destination.id, universe: pulse.universe)
        streams[key] = destination
        let now = ProcessInfo.processInfo.systemUptime
        mixer.start(pulse, in: key, at: now)
        send(key, at: now)
        // Send the release the moment it's due (plus a hair, so the pulse has ended).
        DispatchQueue.main.asyncAfter(deadline: .now() + pulse.duration + 0.001) { [weak self] in
            self?.send(key, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    enum PulseError: LocalizedError {
        case noDMXOutput(String)
        case universeOutOfRange(Int, DMXOutput)

        var errorDescription: String? {
            switch self {
            case .noDMXOutput(let name): return "DMX is off for \(name) (Destinations tab)"
            case .universeOutOfRange(let universe, let output):
                return "universe \(universe) is outside \(output.name)'s range \(output.universeRange.lowerBound)-\(output.universeRange.upperBound)"
            }
        }
    }

    private func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        for (key, destination) in streams where now - (lastSent[key] ?? -.infinity) >= 1 / destination.dmxRefreshRate - Self.tick / 2 {
            send(key, at: now)
        }
    }

    private func send(_ key: UniverseKey, at time: Double) {
        guard let destination = streams[key], let output = destination.activeDMXOutput else { return }
        let slots = mixer.levels(key, at: time)
        lastSent[key] = time
        let sequence = nextSequence(key, output: output)
        let bytes: [UInt8]
        let host: String
        let port: UInt16
        switch output {
        case .artNet:
            bytes = ArtDmxPacket(portAddress: key.universe, sequence: sequence, data: slots).encoded
            host = destination.dmxHost
            port = artNetPort
        case .sACNMulticast, .sACNUnicast:
            bytes = SACNDataPacket(cid: cid, sourceName: destination.dmxSourceName, universe: key.universe,
                                   priority: destination.sacnPriority, sequence: sequence, data: slots).encoded
            host = output == .sACNMulticast ? SACNDataPacket.multicastAddress(universe: key.universe) : destination.dmxHost
            port = SACNDataPacket.port
        }
        do {
            try sender.send(bytes, to: host, port: port, interface: destination.dmxInterface)
            failing.remove(key)
        } catch {
            if failing.insert(key).inserted {
                onError?("\(destination.name) \(output.name) universe \(key.universe): \(error.localizedDescription)")
            }
        }
    }

    /// Art-Net sequences run 1...255 (0 means "don't reorder"); sACN 0...255.
    private func nextSequence(_ key: UniverseKey, output: DMXOutput) -> UInt8 {
        let current = sequences[key] ?? 0
        var next = current &+ 1
        if output == .artNet, next == 0 { next = 1 }
        sequences[key] = next
        return next
    }

    /// sACN senders keep one 16-byte component ID for life; store it once per Mac.
    private static func componentID() -> [UInt8] {
        let key = "TrigIT.sACN.CID"
        if let stored = UserDefaults.standard.data(forKey: key), stored.count == 16 {
            return Array(stored)
        }
        let id = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        UserDefaults.standard.set(Data(id), forKey: key)
        return id
    }
}
