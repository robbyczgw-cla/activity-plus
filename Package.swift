// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ActivityPlus",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ActivityPlus", targets: ["ActivityPlus"]),
        .executable(name: "aplus", targets: ["aplus"]),
        .executable(name: "ActivityPlusHelper", targets: ["ActivityPlusHelper"]),
        // Desktop / Notification Center widgets; scripts/build-app.sh wraps it into Contents/PlugIns/ActivityPlusWidgets.appex.
        .executable(name: "ActivityPlusWidgets", targets: ["ActivityPlusWidgets"]),
    ],
    dependencies: [
        // Auto-updates. The framework is copied into the app bundle by scripts/build-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        // Samplers and models. No UI imports, so it stays testable and reusable (CLI later).
        .target(
            name: "ActivityCore",
            dependencies: ["WidgetData"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The snapshot the app hands to its widgets (Codable, Foundation only).
        .target(name: "WidgetData", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Widget views, shared by the extension and the app's SnapshotRunner.
        .target(name: "WidgetUI", dependencies: ["WidgetData"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // A WidgetKit app extension built as a plain executable, linked the way Xcode links app extensions:
        // entry point _NSExtensionMain (sets up the extension's XPC run loop; a plain main() just returns
        // and the extension exits) and extension-safe API only.
        .executableTarget(
            name: "ActivityPlusWidgets",
            dependencies: ["WidgetData", "WidgetUI"],
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"])]
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
            dependencies: ["ActivityCore", "HelperShared", "WidgetData", "WidgetUI", .product(name: "Sparkle", package: "Sparkle")],
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
            dependencies: ["ActivityCore", "WidgetData"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
