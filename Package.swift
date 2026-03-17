// swift-tools-version: 6.2
// PKT-318: Added swift-nio for SSE transport on :9700
// PKT-353: Platform bumped to macOS 26 (Tahoe) for Liquid Glass adoption.
//   swift-tools-version bumped 6.0 → 6.2 (required for .macOS(.v26)).
import PackageDescription

let package = Package(
    name: "NotionBridge",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NotionBridge", targets: ["NotionBridge"]),
        .executable(name: "NotionBridgeTests", targets: ["NotionBridgeTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "NotionBridgeLib",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "NotionBridge",
            exclude: ["App/NotionBridgeApp.swift", "App/Resources", "App/Info.plist"]
        ),
        .executableTarget(
            name: "NotionBridge",
            dependencies: ["NotionBridgeLib"],
            path: "NotionBridge/App",
            exclude: ["AppDelegate.swift", "StatusBarController.swift", "Info.plist"],
            sources: ["NotionBridgeApp.swift"],
            resources: [.process("Resources")]
        ),
        // Standalone test executable (not .testTarget) — uses custom test harness
        // in main.swift instead of XCTest. Run via: swift run NotionBridgeTests
        .executableTarget(
            name: "NotionBridgeTests",
            dependencies: ["NotionBridgeLib",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "NotionBridgeTests"
        ),
    ]
)
