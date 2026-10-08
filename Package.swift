// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wink",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Wink", targets: ["Wink"])],
    targets: [
        .target(name: "WinkCore"),
        .executableTarget(name: "Wink", dependencies: ["WinkCore"]),
        .testTarget(name: "WinkCoreTests", dependencies: ["WinkCore"])
    ]
)
