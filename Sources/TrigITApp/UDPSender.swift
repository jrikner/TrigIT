import Foundation
import Network
import TrigITEngine

/// A network interface the user can send through.
struct NetworkInterfaceInfo: Hashable, Identifiable {
    var name: String
    var kind: String
    var id: String { name }

    var label: String { "\(name) (\(kind))" }
}

/// Sends UDP datagrams to Destinations. When a Destination names a network
/// interface, traffic goes out through that interface only; if it is
/// missing, nothing is sent and an error is reported.
final class UDPSender {
    enum SendError: LocalizedError {
        case interfaceUnavailable(String)
        case invalidPort

        var errorDescription: String? {
            switch self {
            case .interfaceUnavailable(let name): return "network interface \(name) is not available"
            case .invalidPort: return "port 0 is not valid"
            }
        }
    }

    private struct ConnectionKey: Hashable {
        var host: String
        var port: UInt16
        var interface: String?
    }

    /// Called on the main queue whenever the list of interfaces changes.
    var onInterfacesChanged: (([NetworkInterfaceInfo]) -> Void)?

    // Everything below is only touched on `queue`.
    private let queue = DispatchQueue(label: "TrigIT.UDPSender")
    private let monitor = NWPathMonitor()
    private var interfaces: [String: NWInterface] = [:]
    private var connections: [ConnectionKey: NWConnection] = [:]

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.interfaces = Dictionary(path.availableInterfaces.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let infos = path.availableInterfaces
                .map { NetworkInterfaceInfo(name: $0.name, kind: Self.describe($0.type)) }
                .sorted { $0.name < $1.name }
            DispatchQueue.main.async { self.onInterfacesChanged?(infos) }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        connections.values.forEach { $0.cancel() }
    }

    /// Sends `bytes` as one datagram. `completion` runs on the main queue with
    /// nil on success.
    func send(_ bytes: [UInt8], to destination: Destination, completion: @escaping (Error?) -> Void) {
        let finish: (Error?) -> Void = { error in DispatchQueue.main.async { completion(error) } }
        queue.async { [self] in
            guard destination.port != 0 else { return finish(SendError.invalidPort) }
            let key = ConnectionKey(host: destination.host, port: destination.port, interface: destination.networkInterface)
            guard let connection = connection(for: key) else {
                return finish(SendError.interfaceUnavailable(destination.networkInterface ?? "?"))
            }
            connection.send(content: Data(bytes), completion: .contentProcessed { error in finish(error) })
        }
    }

    /// An open connection for the key, created on first use. Returns nil when
    /// the required interface is not present.
    private func connection(for key: ConnectionKey) -> NWConnection? {
        if let existing = connections[key] { return existing }
        let parameters = NWParameters.udp
        if let name = key.interface {
            guard let interface = interfaces[name] else { return nil }
            parameters.requiredInterface = interface
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(key.host),
            port: NWEndpoint.Port(rawValue: key.port)!,
            using: parameters
        )
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                // Drop it so the next send builds a fresh connection.
                self?.queue.async { self?.connections[key] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        connections[key] = connection
        return connection
    }

    private static func describe(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wiredEthernet: return "Ethernet"
        case .wifi: return "Wi-Fi"
        case .loopback: return "Loopback"
        case .cellular: return "Cellular"
        case .other: return "Other"
        @unknown default: return "Other"
        }
    }
}
