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

The Show Engine (`Sources/TrigITEngine`) is pure Swift with no platform dependencies, so its tests also run on Linux. The SwiftUI app (`Sources/TrigITApp`) only builds on macOS.
