// swift-tools-version: 5.9
import PackageDescription

// The Show Engine is pure Swift with no platform dependencies, so it builds
// and tests on any platform. The SwiftUI app target only exists on macOS.
var products: [Product] = [
    .library(name: "TrigITEngine", targets: ["TrigITEngine"]),
]

var targets: [Target] = [
    .target(name: "TrigITEngine"),
    .testTarget(name: "TrigITEngineTests", dependencies: ["TrigITEngine"]),
]

#if os(macOS)
products.append(.executable(name: "TrigIT", targets: ["TrigITApp"]))
targets.append(.executableTarget(name: "TrigITApp", dependencies: ["TrigITEngine"]))
#endif

let package = Package(
    name: "TrigIT",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
