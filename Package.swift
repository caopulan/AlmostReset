// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AlmostReset",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AlmostResetCore", targets: ["AlmostResetCore"]), .executable(name: "AlmostReset", targets: ["AlmostResetApp"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "AlmostResetCore"),
        .executableTarget(name: "AlmostResetApp", dependencies: ["AlmostResetCore", .product(name: "Sparkle", package: "Sparkle")], resources: [.process("Resources")]),
        .testTarget(name: "AlmostResetCoreTests", dependencies: ["AlmostResetCore"])
    ],
    swiftLanguageModes: [.v5]
)
