// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ActivityPlus",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ActivityPlus", targets: ["ActivityPlus"]),
        .executable(name: "aplus", targets: ["aplus"]),
    ],
    targets: [
        // Samplers and models. No UI imports, so it stays testable and reusable (CLI later).
        .target(
            name: "ActivityCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ActivityPlus",
            dependencies: ["ActivityCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "aplus",
            dependencies: ["ActivityCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ActivityCoreTests",
            dependencies: ["ActivityCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
