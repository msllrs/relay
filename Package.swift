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
    targets: [
        .executableTarget(
            name: "Relay",
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
