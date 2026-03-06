// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Relay", targets: ["Relay"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "Relay",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Relay",
            exclude: [
                "Info.plist",
                "Relay.entitlements"
            ],
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)
