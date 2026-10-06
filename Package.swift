// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LidEffort",
    defaultLocalization: "en",
    platforms: [.macOS("15.0")],
    dependencies: [
        // Only for the local Ollama relay (`Sessions/OllamaRelayServer.swift`).
        // Everything else is Foundation.
        .package(url: "https://github.com/apple/swift-nio", from: "2.102.0"),
        // Updates: the signed appcast on the GitHub releases, checked in the background.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        // Pure logic: the lid gesture, motion classification, per-model effort
        // scales, config patching. No AppKit, fully unit-tested.
        .target(name: "LidEffortCore"),

        // Vendored Zstandard decoder: Claude Desktop's HTTP cache stores usage
        // bodies zstd-encoded and macOS ships no decoder. BSD, see THIRD_PARTY_NOTICES.md.
        .target(
            name: "CZstd",
            cSettings: [.define("ZSTD_STRIP_ERROR_STRINGS", to: "1")]
        ),

        // The app: the notch, usage providers, session monitors and the
        // lid-effort module driving them.
        .executableTarget(
            name: "LidEffort",
            dependencies: [
                "LidEffortCore",
                "CZstd",
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/Assets.xcassets"),
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/LobeIcons-LICENSE.txt"),
                .copy("Resources/SimpleIcons-LICENSE.txt"),
            ]
        ),

        .testTarget(name: "LidEffortCoreTests", dependencies: ["LidEffortCore"]),
        .testTarget(name: "LidEffortTests", dependencies: ["LidEffort", "LidEffortCore"]),
    ]
)
