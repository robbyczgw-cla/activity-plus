// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ActivityPlus",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ActivityPlus", targets: ["ActivityPlus"]),
        .executable(name: "aplus", targets: ["aplus"]),
        .executable(name: "ActivityPlusHelper", targets: ["ActivityPlusHelper"]),
    ],
    dependencies: [
        // Auto-updates. The framework is copied into the app bundle by scripts/build-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        // Samplers and models. No UI imports, so it stays testable and reusable (CLI later).
        .target(
            name: "ActivityCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Shared XPC interface between the app and its privileged helper.
        .target(name: "HelperShared", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ActivityPlusHelper",
            dependencies: ["HelperShared"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ActivityPlus",
            dependencies: ["ActivityCore", "HelperShared", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
