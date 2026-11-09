// SPDX-License-Identifier: GPL-3.0-or-later

/// What the Windows spike was asked to do on its command line.
///
///     TrigITWindows <set.trigit> [--source artnet|ltc]... [--ltc-device <name>]
///                   [--ltc-channel <n>] [--artnet-port <port>] [--report <file>]
///                   [--duration <seconds>] [--ui-port <port>] [--no-browser]
///     TrigITWindows --list-devices
///
/// The first `--source` is the Primary Source, a second one the Backup Source.
public struct SpikeOptions: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case artNet = "artnet"
        case ltc
    }

    public var setPath: String?
    /// Primary first, then the optional Backup.
    public var sources: [Source] = [.artNet]
    /// Part of the audio input's name; nil: the Windows default recording device.
    public var ltcDevice: String?
    /// 1-based, as on the audio interface.
    public var ltcChannel = 1
    public var artNetPort: UInt16 = 6454
    public var reportPath: String?
    /// Stop by itself after this many seconds; nil: run until Ctrl+C.
    public var duration: Double?
    public var listDevices = false
    /// The browser UI's port on 127.0.0.1; 0: no UI.
    public var uiPort: UInt16 = 7319
    /// Don't open the UI in the default browser at start.
    public var noBrowser = false

    public init() {}

    public static let usage = """
        Usage:
          TrigITWindows <set.trigit> [options]   follow timecode and fire the Set's OSC Actions
          TrigITWindows --list-devices            list audio inputs for --ltc-device

        Options:
          --source artnet|ltc   a Timecode Source; give it twice for Primary and Backup (default: artnet)
          --ltc-device <name>   part of the audio input's name (default: the Windows default recording device)
          --ltc-channel <n>     input channel carrying LTC, from 1 (default: 1)
          --artnet-port <port>  UDP port for Art-Net Timecode (default: 6454)
          --report <file>       where to write the timing report (default: TrigIT-timing-report-<time>.txt)
          --duration <seconds>  stop by itself after this long (default: run until Ctrl+C)
          --ui-port <port>      the browser UI at http://127.0.0.1:<port>, 0 for none (default: 7319)
          --no-browser          serve the UI but don't open the browser
        """

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// Parses the arguments after the program name.
    public init(arguments: [String]) throws {
        var explicitSources: [Source] = []
        var rest = arguments[...]
        func value(for flag: String) throws -> String {
            guard let value = rest.popFirst() else { throw ParseError(description: "\(flag) needs a value") }
            return value
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--source":
                let name = try value(for: argument)
                guard let source = Source(rawValue: name.lowercased()) else {
                    throw ParseError(description: "unknown source \"\(name)\" (use artnet or ltc)")
                }
                guard !explicitSources.contains(source) else { throw ParseError(description: "\(name) is given twice") }
                guard explicitSources.count < 2 else { throw ParseError(description: "at most two sources: Primary and Backup") }
                explicitSources.append(source)
            case "--ltc-device":
                ltcDevice = try value(for: argument)
            case "--ltc-channel":
                guard let channel = Int(try value(for: argument)), channel >= 1 else {
                    throw ParseError(description: "--ltc-channel must be 1 or more")
                }
                ltcChannel = channel
            case "--artnet-port":
                guard let port = UInt16(try value(for: argument)), port > 0 else {
                    throw ParseError(description: "--artnet-port must be 1 to 65535")
                }
                artNetPort = port
            case "--report":
                reportPath = try value(for: argument)
            case "--duration":
                guard let seconds = Double(try value(for: argument)), seconds > 0 else {
                    throw ParseError(description: "--duration must be a positive number of seconds")
                }
                duration = seconds
            case "--ui-port":
                guard let port = UInt16(try value(for: argument)) else {
                    throw ParseError(description: "--ui-port must be 0 to 65535")
                }
                uiPort = port
            case "--no-browser":
                noBrowser = true
            case "--list-devices":
                listDevices = true
            case "-h", "--help":
                throw ParseError(description: "")
            default:
                guard !argument.hasPrefix("-") else { throw ParseError(description: "unknown option \(argument)") }
                guard setPath == nil else { throw ParseError(description: "only one Set file, please") }
                setPath = argument
            }
        }
        if !explicitSources.isEmpty { sources = explicitSources }
        if setPath == nil, !listDevices { throw ParseError(description: "give the .trigit Set file to follow") }
    }
}
