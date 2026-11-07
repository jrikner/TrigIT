import Darwin
import Foundation
import TrigITProtocols

/// Listens for Art-Net packets on UDP port 6454.
///
/// A plain BSD socket rather than Network.framework, because it reliably
/// receives broadcast packets (Art-Net Timecode is usually broadcast), can
/// share the port with other Art-Net software on the same Mac, and can be
/// locked to one interface with IP_BOUND_IF so packets arriving on any other
/// interface are dropped by the kernel.
final class ArtNetTimecodeInput {
    enum StartError: LocalizedError {
        case socket(call: String, reason: String)
        case unknownInterface(String)

        /// Captures errno now, before anything else can change it.
        static func failed(_ call: String) -> StartError {
            .socket(call: call, reason: String(cString: strerror(errno)))
        }

        var errorDescription: String? {
            switch self {
            case .socket(let call, let reason): return "could not open UDP port \(artNetPort) (\(call): \(reason))"
            case .unknownInterface(let name): return "network interface \(name) is not available"
            }
        }
    }

    /// Called on the main queue with each received datagram and the monotonic
    /// time it arrived (same clock as `ProcessInfo.systemUptime`).
    var onPacket: (([UInt8], Double) -> Void)?

    private let queue = DispatchQueue(label: "TrigIT.ArtNetTimecodeInput")
    private var source: DispatchSourceRead?

    /// Starts listening; `interface` is a BSD name such as "en1", or nil for every interface.
    func start(interface: String?) throws {
        stop()
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw StartError.failed("socket") }
        var opened = false
        defer { if !opened { close(fd) } }

        var yes: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, size) == 0,
              setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, size) == 0
        else { throw StartError.failed("setsockopt") }

        if let interface {
            var index = if_nametoindex(interface)
            guard index != 0 else { throw StartError.unknownInterface(interface) }
            guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
            else { throw StartError.failed("IP_BOUND_IF") }
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = artNetPort.bigEndian
        address.sin_addr = in_addr(s_addr: 0) // any address, so broadcasts arrive too
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw StartError.failed("bind") }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw StartError.failed("fcntl") }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        opened = true
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }

    /// Runs on `queue`: reads every waiting datagram.
    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1_500)
        var packets: [[UInt8]] = []
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { break }
            packets.append(Array(buffer.prefix(count)))
        }
        guard !packets.isEmpty else { return }
        let time = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            for packet in packets { self?.onPacket?(packet, time) }
        }
    }
}
