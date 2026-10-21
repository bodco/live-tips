// swift-tools-version:5.9
// LiveTips.app M0 skeleton: menu bar app, permission probe, helper supervision with heartbeat.
// Builds with the Command Line Tools (no Xcode): `swift build -c release`.
import PackageDescription

let package = Package(
    name: "LiveTips",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LiveTips", targets: ["LiveTips"]),
    ],
    targets: [
        .target(name: "LiveTipsCore"),
        .executableTarget(name: "LiveTips", dependencies: ["LiveTipsCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["LiveTipsCore"]),
    ]
)
