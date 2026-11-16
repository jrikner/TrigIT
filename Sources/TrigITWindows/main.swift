// SPDX-License-Identifier: GPL-3.0-or-later

// The Windows spike (issue #1): follows Art-Net Timecode and/or LTC, fires a
// Set's OSC Actions through the Show Engine, and writes a timing report on
// exit. The Windows calls live in CWindowsIO; the logic in TrigITSpike.

import CWindowsIO
import Foundation
import TrigITEngine
import TrigITProtocols
import TrigITSpike
import TrigITStorage

func fail(_ message: String) -> Never {
    print("Error: \(message)")
    exit(1)
}

/// A C string buffer for error messages and names.
func buffer() -> [CChar] { [CChar](repeating: 0, count: 512) }
func string(_ buffer: [CChar]) -> String { buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } }

let options: SpikeOptions
do {
    options = try SpikeOptions(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    let message = "\(error)"
    if !message.isEmpty { print("Error: \(message)\n") }
    print(SpikeOptions.usage)
    exit(message.isEmpty ? 0 : 2)
}

if options.listDevices {
    print("Audio inputs (use part of a name with --ltc-device):")
    var error = buffer()
    let status = cwio_audio_list({ _, name, isDefault in
        print("  \(name.map { String(cString: $0) } ?? "?")\(isDefault != 0 ? "   (default)" : "")")
    }, nil, &error, Int32(error.count))
    if status != 0 { fail(string(error)) }
    exit(0)
}

let setURL = URL(fileURLWithPath: options.setPath!)
let set: ShowSet
do { set = try SetFile.read(from: setURL) } catch { fail("\(setURL.path): \(error)") }

func role(of source: SpikeOptions.Source) -> SourceRole? {
    options.sources.firstIndex(of: source).map { $0 == 0 ? .primary : .backup }
}

// MARK: Shared state, guarded by `lock`

let lock = NSLock()
var session = SpikeSession(set: set, startedAt: cwio_now())
var stopRequested = false
var ltcPeak: Float = 0

// MARK: Sending

var error = buffer()
let sender = cwio_udp_sender(&error, Int32(error.count))
if sender < 0 { fail(string(error)) }
var addresses: [String: UInt32] = [:]
for destination in set.destinations where destination.usesOSC && addresses[destination.host] == nil {
    var address: UInt32 = 0
    if cwio_udp_resolve(destination.host, &address) == 0 {
        addresses[destination.host] = address
    } else {
        print("Warning: cannot find \(destination.host) (Destination \(destination.name)); its sends will fail")
    }
}

/// Runs one input through the session under the lock, sends its datagrams
/// at once, then prints its notes (console output is slow on Windows).
func run(_ input: (inout SpikeSession) -> SpikeSession.Step) {
    lock.lock()
    let step = input(&session)
    var failures: [String] = []
    for send in step.sends {
        var message: String?
        if let address = addresses[send.host] {
            let code = send.bytes.withUnsafeBufferPointer {
                cwio_udp_send(sender, address, send.port, $0.baseAddress, Int32($0.count))
            }
            if code != 0 { message = "Winsock error \(code)" }
        } else {
            message = "cannot find \(send.host)"
        }
        session.sent(send, at: cwio_now(), error: message)
        if let message { failures.append("OSC to \(send.host):\(send.port) failed: \(message)") }
    }
    lock.unlock()
    for line in step.notes + failures { print(line) }
    // Through a pipe Windows buffers stdout fully; show lines as they happen.
    if !step.notes.isEmpty || !failures.isEmpty { fflush(nil) }
}

// MARK: Art-Net Timecode

var sourceLines: [String] = []

if let artNetRole = role(of: .artNet) {
    var error = buffer()
    let socket = cwio_udp_listen(options.artNetPort, &error, Int32(error.count))
    if socket < 0 { fail("Art-Net on UDP port \(options.artNetPort): \(string(error))") }
    sourceLines.append("Art-Net Timecode on UDP port \(options.artNetPort) (\(artNetRole.rawValue))")
    let thread = Thread {
        var packet = [UInt8](repeating: 0, count: 1_500)
        while true {
            let count = packet.withUnsafeMutableBufferPointer { cwio_udp_receive(socket, $0.baseAddress, Int32($0.count)) }
            let time = cwio_now()
            guard count > 0 else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            let bytes = Array(packet.prefix(Int(count)))
            run { $0.receiveArtNet(bytes, arrivedAt: time, role: artNetRole) }
        }
    }
    thread.start()
}

// MARK: LTC

// Touched only on the capture thread (ltcPeak under the lock).
var ltcDecoder: LTCDecoder?
var ltcSamplesFed = 0
var ltcRole = SourceRole.primary

if let role = role(of: .ltc) {
    ltcRole = role
    var error = buffer()
    var name = buffer()
    var sampleRate = 0.0
    var period = 0.0
    let status = cwio_audio_start(options.ltcDevice ?? "", Int32(options.ltcChannel - 1), { _, samples, count, rate, first, arrival in
        guard let samples, count > 0 else { return }
        let block = Array(UnsafeBufferPointer(start: samples, count: Int(count)))
        if ltcDecoder == nil { ltcDecoder = LTCDecoder(sampleRate: rate) }
        let blockStart = ltcSamplesFed
        ltcSamplesFed += block.count
        let peak = block.reduce(Float(0)) { max($0, abs($1)) }
        lock.lock()
        ltcPeak = max(ltcPeak, peak)
        lock.unlock()
        for frame in ltcDecoder!.decode(block) {
            let start = first + Double(frame.startSample - blockStart) / rate
            run { $0.receiveLTC(frame, startedAt: start, arrivedAt: arrival, role: ltcRole) }
        }
    }, nil, &name, Int32(name.count), &sampleRate, &period, &error, Int32(error.count))
    if status != 0 { fail("LTC input: \(string(error))") }
    let buffers = String(format: "%.1f", period * 1000)
    sourceLines.append("LTC from \"\(string(name))\" channel \(options.ltcChannel), \(Int(sampleRate)) Hz, \(buffers) ms audio buffers (\(role.rawValue))")
}

// MARK: Browser UI

var uiLine: String?
if options.uiPort != 0 {
    var error = buffer()
    let listener = cwio_tcp_listen(options.uiPort, &error, Int32(error.count))
    if listener < 0 { fail("browser UI on TCP port \(options.uiPort): \(string(error)) (another --ui-port, or 0 for none)") }
    let url = "http://127.0.0.1:\(options.uiPort)/"
    uiLine = "Browser UI: \(url)"
    // One request at a time: the page polls a few small requests a second.
    let thread = Thread {
        var request = [UInt8](repeating: 0, count: 8_192)
        while true {
            let connection = cwio_tcp_accept(listener)
            guard connection >= 0 else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            let count = request.withUnsafeMutableBufferPointer {
                cwio_tcp_read_request(connection, $0.baseAddress, Int32($0.count))
            }
            let response = WebUI.respond(to: count > 0 ? Array(request.prefix(Int(count))) : []) {
                lock.lock()
                defer { lock.unlock() }
                return session.status()
            }
            response.withUnsafeBufferPointer { cwio_tcp_send_and_close(connection, $0.baseAddress, Int32($0.count)) }
        }
    }
    thread.start()
    if !options.noBrowser { cwio_open_url(url) }
}

// MARK: Clock and report

let tickPeriod = 0.01
guard let timerName = cwio_timer_open(Int32(tickPeriod * 1_000_000)).map({ String(cString: $0) }) else {
    fail("could not create a timer")
}
cwio_on_interrupt {
    lock.lock()
    stopRequested = true
    lock.unlock()
}

print("TrigIT Windows spike: following \(set.name) (\(set.songs.count) Songs)")
for line in sourceLines { print("  \(line)") }
print("Timer: \(timerName)")
if let uiLine { print(uiLine) }
print(options.duration.map { "Running for \($0) s; Ctrl+C stops sooner." } ?? "Press Ctrl+C to stop and write the timing report.")
fflush(nil)

let startedAt = cwio_now()
var lastStatus = startedAt
while true {
    cwio_timer_wait()
    let now = cwio_now()
    lock.lock()
    let stop = stopRequested
    lock.unlock()
    if stop || options.duration.map({ now - startedAt >= $0 }) == true { break }
    run { $0.tick(at: now) }
    if now - lastStatus >= 5 {
        lastStatus = now
        lock.lock()
        let playhead = session.engine.playhead.map { "\($0)" } ?? "no timecode yet"
        let level = ltcPeak > 0 ? String(format: ", LTC input peak %.0f dBFS", 20 * log10(Double(ltcPeak))) : ""
        ltcPeak = 0
        lock.unlock()
        print("[status] playhead \(playhead)\(role(of: .ltc) != nil && level.isEmpty ? ", LTC input silent" : level)")
        fflush(nil)
    }
}

let stamp: String = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}()
let reportURL = URL(fileURLWithPath: options.reportPath ?? "TrigIT-timing-report-\(stamp).txt")
let environment = SpikeSession.Environment(
    computer: "\(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.activeProcessorCount) logical processors",
    setName: set.name, sources: sourceLines.joined(separator: "; "), timer: timerName, tickPeriod: tickPeriod)
// Held until exit, so the input threads send nothing the report leaves out.
lock.lock()
let report = session.report(environment, endedAt: cwio_now())
do {
    try report.write(to: reportURL, atomically: true, encoding: .utf8)
    print("\nTiming report written to \(reportURL.path)")
    print("Please attach it to a comment on https://github.com/jrikner/TrigIT/issues/1")
} catch {
    print(report)
    fail("could not write the report to \(reportURL.path): \(error)")
}
exit(0)
