// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SousBar",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "SousBar", targets: ["SousBar"]),
        .executable(name: "sousbar-hook", targets: ["sousbar-hook"]),
    ],
    targets: [
        .target(name: "SousCore"),
        .executableTarget(name: "SousBar", dependencies: ["SousCore"]),
        .executableTarget(name: "sousbar-hook", dependencies: ["SousCore"]),
        .testTarget(name: "SousBarTests", dependencies: ["SousBar", "SousCore"]),
        .testTarget(name: "HookTests", dependencies: ["sousbar-hook", "SousCore"]),
        .testTarget(name: "SousCoreTests", dependencies: ["SousCore"]),
    ]
)
