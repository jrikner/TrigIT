// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

// The Show Engine and the protocol codecs are pure Swift with no platform
// dependencies, so they build and test on any platform. The SwiftUI app
// target only exists on macOS.
var products: [Product] = [
    .library(name: "TrigITEngine", targets: ["TrigITEngine"]),
    .library(name: "TrigITProtocols", targets: ["TrigITProtocols"]),
    .library(name: "TrigITStorage", targets: ["TrigITStorage"]),
]

var targets: [Target] = [
    // Pure encoders and decoders for the show protocols (OSC, MIDI, Art-Net, sACN, LTC).
    .target(name: "TrigITProtocols"),
    .testTarget(
        name: "TrigITProtocolsTests",
        dependencies: ["TrigITProtocols"],
        // Reference LTC recordings made with libltc (see Fixtures/README.md).
        resources: [.copy("Fixtures")]
    ),
    // The Show Engine: follows timecode and decides what fires. No I/O.
    .target(name: "TrigITEngine", dependencies: ["TrigITProtocols"]),
    .testTarget(name: "TrigITEngineTests", dependencies: ["TrigITEngine"]),
    // Set files on disk: the file format, previous versions, undo history.
    .target(name: "TrigITStorage", dependencies: ["TrigITEngine"]),
    // Fixtures: what grandMA3 onPC exported, read by path (MA3ExportTests).
    .testTarget(name: "TrigITStorageTests", dependencies: ["TrigITStorage"], exclude: ["Fixtures"]),
    // The Windows spike's platform-free half (issue #1): argument parsing,
    // the engine loop and the timing report. Built everywhere so its tests run everywhere.
    .target(name: "TrigITSpike", dependencies: ["TrigITEngine", "TrigITProtocols"]),
    .testTarget(name: "TrigITSpikeTests", dependencies: ["TrigITSpike", "TrigITStorage"]),
]

#if os(macOS)
products.append(.executable(name: "TrigIT", targets: ["TrigITApp"]))
targets.append(.executableTarget(name: "TrigITApp", dependencies: ["TrigITEngine", "TrigITProtocols", "TrigITStorage"]))
#endif

#if os(Windows)
// The Windows spike: a console app that follows Art-Net Timecode and LTC and
// fires a Set's OSC Actions, measuring the timing (see docs/windows-spike.md).
products.append(.executable(name: "TrigITWindows", targets: ["TrigITWindows"]))
targets.append(.target(
    name: "CWindowsIO",
    linkerSettings: [.linkedLibrary("ws2_32"), .linkedLibrary("ole32"), .linkedLibrary("winmm"), .linkedLibrary("avrt"), .linkedLibrary("shell32")]
))
targets.append(.executableTarget(
    name: "TrigITWindows",
    dependencies: ["TrigITSpike", "TrigITStorage", "TrigITProtocols", "CWindowsIO"]
))
#endif

let package = Package(
    name: "TrigIT",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
