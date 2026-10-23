// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AlmostReset",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AlmostResetCore", targets: ["AlmostResetCore"]), .executable(name: "AlmostReset", targets: ["AlmostResetApp"])],
    targets: [
        .target(name: "AlmostResetCore"),
        .executableTarget(name: "AlmostResetApp", dependencies: ["AlmostResetCore"], resources: [.process("Resources")]),
        .testTarget(name: "AlmostResetCoreTests", dependencies: ["AlmostResetCore"])
    ],
    swiftLanguageModes: [.v5]
)
