// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Onward",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Onward", targets: ["Onward"])],
    targets: [
        .target(name: "OnwardCore"),
        .executableTarget(name: "Onward", dependencies: ["OnwardCore"]),
        .testTarget(name: "OnwardCoreTests", dependencies: ["OnwardCore"])
    ]
)
