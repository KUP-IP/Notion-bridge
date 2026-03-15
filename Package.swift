// swift-tools-version: 6.0
// PKT-318: Added swift-nio for SSE transport on :9700
import PackageDescription

let package = Package(
    name: "NotionBridge",
    platforms: [.macOS(.v14)],
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
            exclude: ["Server/main.swift", "App/NotionBridgeApp.swift", "App/Resources"]
        ),
        .executableTarget(
            name: "NotionBridge",
            dependencies: ["NotionBridgeLib"],
            path: "NotionBridge/App",
            sources: ["NotionBridgeApp.swift"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "NotionBridgeTests",
            dependencies: ["NotionBridgeLib",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "NotionBridgeTests"
        ),
    ]
)
