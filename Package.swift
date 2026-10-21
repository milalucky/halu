// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Halu",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "HaluCore"),
        .executableTarget(name: "Halu", dependencies: ["HaluCore"]),
        .executableTarget(name: "halu-hook", dependencies: ["HaluCore"], path: "Sources/HaluHook"),
    ],
    swiftLanguageModes: [.v5]
)
