import Darwin
import Foundation
import Network
import TrigITEngine

/// Runs the Destination status checks: pings each network Destination through
/// its chosen interface, listens for OSC replies, and feeds what it sees to a
/// `DestinationMonitor`. Pings run on their own queue and sockets, apart from
/// `UDPSender` and `MIDIOutput`, so checks never delay sending Actions.
@MainActor
final class DestinationChecker {
    /// What the checks need, read on the main queue each second.
    struct Inputs {
        var set: ShowSet
        /// BSD names of the interfaces present, or nil while not yet known.
        var interfaces: Set<String>?
        var midiOutputs: Set<Int32>
    }

    private var monitor = DestinationMonitor()
    private var timer: Timer?
    private var ticks = 0
    private var listeners: [UInt16: NWListener] = [:]
    private var inputs: (() -> Inputs?)?
    private var onUpdate: (([DestinationID: DestinationStatus], [DestinationStatusChange]) -> Void)?
    private var onListenerError: ((String) -> Void)?
    private var lastInputs: Inputs?

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func start(inputs: @escaping () -> Inputs?,
               onUpdate: @escaping ([DestinationID: DestinationStatus], [DestinationStatusChange]) -> Void,
               onListenerError: @escaping (String) -> Void) {
        self.inputs = inputs
        self.onUpdate = onUpdate
        self.onListenerError = onListenerError
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let inputs = inputs?() else { return }
        lastInputs = inputs
        if ticks % Int(DestinationMonitor.pingInterval) == 0 {
            for destination in inputs.set.destinations { ping(destination, inputs) }
        }
        ticks += 1
        updateListeners(Set(inputs.set.destinations.compactMap(\.replyPort)))
        publish()
    }

    /// Recomputes the statuses from the latest inputs and reports them.
    private func publish() {
        guard let inputs = lastInputs else { return }
        let changes = monitor.update(inputs.set, interfaces: inputs.interfaces, midiOutputs: inputs.midiOutputs, at: now)
        onUpdate?(monitor.statuses, changes)
    }

    /// Pings the Destination now rather than at the next interval, so a Send
    /// Test settles within about a second.
    func checkNow(_ destination: Destination) {
        guard let inputs = lastInputs else { return }
        ping(destination, inputs)
    }

    /// A send finished; shows as Sent (not as Reachable) or as its error.
    func sendFinished(_ id: DestinationID, over transport: Transport, error: String?) {
        monitor.sendFinished(id, over: transport, error: error, at: now)
        publish()
    }

    private func ping(_ destination: Destination, _ inputs: Inputs) {
        for target in DestinationMonitor.pingTargets(of: destination) {
            // A missing interface is already offline; there's nothing to ping through.
            if let interface = target.networkInterface, inputs.interfaces?.contains(interface) == false { continue }
            let id = destination.id
            Pinger.ping(target.host, interface: target.networkInterface) { [weak self] answered in
                guard let self else { return }
                if answered {
                    self.monitor.pingAnswered(id, host: target.host, at: self.now)
                } else {
                    self.monitor.pingFailed(id, host: target.host, at: self.now)
                }
                self.publish()
            }
        }
    }

    // MARK: OSC replies

    private func updateListeners(_ ports: Set<UInt16>) {
        for (port, listener) in listeners where !ports.contains(port) {
            listener.cancel()
            listeners[port] = nil
        }
        for port in ports where listeners[port] == nil && port != 0 {
            do {
                let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
                listener.newConnectionHandler = { [weak self] connection in
                    connection.start(queue: .main)
                    self?.receive(on: connection, port: port)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        DispatchQueue.main.async {
                            self?.onListenerError?("Can't listen for OSC replies on port \(port): \(error.localizedDescription)")
                        }
                    }
                }
                listener.start(queue: .main)
                listeners[port] = listener
            } catch {
                onListenerError?("Can't listen for OSC replies on port \(port): \(error.localizedDescription)")
            }
        }
    }

    // ponytail: one connection per sender, kept open until quit; fine for a handful of devices.
    private nonisolated func receive(on connection: NWConnection, port: UInt16) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if data != nil, case .hostPort(let host, _) = connection.endpoint {
                // Drop an interface scope such as "%en0".
                let address = "\(host)".split(separator: "%").first.map(String.init) ?? ""
                Task { @MainActor in
                    guard let self else { return }
                    guard let set = self.lastInputs?.set else { return }
                    self.monitor.replyReceived(onPort: port, from: address, in: set, at: self.now)
                    self.publish()
                }
            }
            if error == nil { self?.receive(on: connection, port: port) }
        }
    }
}

/// ICMP echo over an unprivileged datagram socket, optionally bound to one
/// network interface. IPv4 only.
enum Pinger {
    private static let queue = DispatchQueue(label: "TrigIT.Pinger", attributes: .concurrent)
    static let timeout = 1.0

    /// `completion` runs on the main queue with whether the host answered.
    static func ping(_ host: String, interface: String?, completion: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            let answered = echo(host, interface: interface)
            DispatchQueue.main.async { completion(answered) }
        }
    }

    private static func echo(_ host: String, interface: String?) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result, let address = result.pointee.ai_addr else { return false }
        defer { freeaddrinfo(result) }
        var target = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if let interface {
            var index = if_nametoindex(interface)
            guard index != 0,
                  setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else { return false }
        }
        var wait = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        let sequence = UInt16.random(in: 0...UInt16.max)
        var packet: [UInt8] = [8, 0, 0, 0, 0x54, 0x49, UInt8(sequence >> 8), UInt8(sequence & 0xFF)] // echo request, id "TI"
        packet += Array("TrigIT".utf8)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        let sent = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 1_500)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard count > 0, from.sin_addr.s_addr == target.sin_addr.s_addr else { continue }
            // macOS hands datagram ICMP sockets the IP header too.
            let start = buffer[0] >> 4 == 4 ? Int(buffer[0] & 0x0F) * 4 : 0
            guard count >= start + 8 else { continue }
            let reply = buffer[start..<count]
            if reply[start] == 0, UInt16(reply[start + 6]) << 8 | UInt16(reply[start + 7]) == sequence { return true }
        }
        return false
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let high = UInt32(bytes[index]) << 8
            sum += index + 1 < bytes.count ? high | UInt32(bytes[index + 1]) : high
        }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
