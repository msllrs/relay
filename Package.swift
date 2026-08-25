// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Relay", targets: ["Relay"]),
        .executable(name: "relay-mcp-server", targets: ["RelayMCPServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // Pinned: 0.12.2+ needs swift-transformers 1.x, which WhisperKit 0.9
        // can't resolve against, and 0.13+ rewrites the StreamingAsrManager
        // API. Widening this range means migrating WhisperKit and
        // FluidAudioEngine together. Until then, building from source needs a
        // Swift ≤6.2 toolchain (0.12.1's AsrManager isn't Sendable).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Relay",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Relay",
            exclude: [
                "Info.plist",
                "Relay.entitlements"
            ],
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources/Sounds")
            ]
        ),
        .executableTarget(
            name: "RelayMCPServer",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "RelayMCPServer"
        )
    ]
)
