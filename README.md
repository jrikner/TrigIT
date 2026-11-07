# TrigIT

A lightweight macOS app that follows show timecode (LTC, MTC, Art-Net Timecode) and fires OSC, MIDI, Art-Net and sACN messages when the timecode enters a Song. See `GLOSSARY.md` for the vocabulary and issue #1 for the spec.

## Run the app (macOS 13+)

```sh
swift run TrigIT
```

Or open `Package.swift` in Xcode and run the `TrigIT` scheme.

## Run the tests

```sh
swift test
```

The Show Engine (`Sources/TrigITEngine`) and the protocol codecs (`Sources/TrigITProtocols`) are pure Swift with no platform dependencies, so their tests also run on Linux. The SwiftUI app (`Sources/TrigITApp`) only builds on macOS.

## LTC input

Pick "LTC: device, channel" as the Timecode Source on the show screen. macOS asks for audio input (microphone) permission the first time; when run with `swift run`, the permission belongs to Terminal (or whichever app launched it).

## MTC input

Pick "MTC: source" as the Timecode Source. Every Core MIDI source is listed: physical ports, network MIDI sessions (set up in Audio MIDI Setup → MIDI Network Setup) and IAC buses (enable "Device is online" for the IAC Driver in Audio MIDI Setup to run on the same Mac as Ableton).

## Art-Net Timecode input

Pick "Art-Net Timecode: interface" as the Timecode Source. TrigIT listens on UDP port 6454 and shares it with other Art-Net software on the same Mac. Choosing an interface means packets arriving on any other interface are ignored.
