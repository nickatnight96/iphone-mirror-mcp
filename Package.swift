// swift-tools-version: 6.0
import PackageDescription

let commonSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("BareSlashRegexLiterals"),
]

let package = Package(
    name: "iphone-mirror-mcp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "MirrorCore",
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "MirrorServer",
            dependencies: [
                "MirrorCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: commonSwiftSettings
        ),
        .executableTarget(
            name: "iphone-mirror-mcp",
            dependencies: ["MirrorServer"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "MirrorCoreTests",
            dependencies: ["MirrorCore"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "MirrorServerTests",
            dependencies: ["MirrorServer"],
            swiftSettings: commonSwiftSettings
        ),
    ]
)
