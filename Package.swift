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
    .testTarget(name: "TrigITStorageTests", dependencies: ["TrigITStorage"]),
]

#if os(macOS)
products.append(.executable(name: "TrigIT", targets: ["TrigITApp"]))
targets.append(.executableTarget(name: "TrigITApp", dependencies: ["TrigITEngine", "TrigITProtocols", "TrigITStorage"]))
#endif

let package = Package(
    name: "TrigIT",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
