// swift-tools-version:5.9
// LiveTips.app M0 skeleton: menu bar app, permission probe, helper supervision with heartbeat.
// Builds with the Command Line Tools (no Xcode): `swift build -c release`.
// 0.16.0 (D3, updates): Sparkle 2 from SwiftPM; bundle.sh copies Sparkle.framework into Contents/Frameworks.
import PackageDescription

let package = Package(
    name: "LiveTips",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LiveTips", targets: ["LiveTips"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "LiveTipsCore"),
        .executableTarget(name: "LiveTips", dependencies: ["LiveTipsCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "CoreChecks", dependencies: ["LiveTipsCore"]),
    ]
)
