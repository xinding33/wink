// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DisplaySwitch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DisplaySwitch", targets: ["DisplaySwitch"])],
    targets: [
        .target(name: "DisplaySwitchCore"),
        .executableTarget(name: "DisplaySwitch", dependencies: ["DisplaySwitchCore"]),
        .testTarget(name: "DisplaySwitchCoreTests", dependencies: ["DisplaySwitchCore"])
    ]
)
