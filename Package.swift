// swift-tools-version: 6.0
// PKT-318: Added swift-nio for SSE transport on :9700
import PackageDescription

let package = Package(
    name: "NotionGate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotionGate", targets: ["NotionGate"]),
        .executable(name: "NotionGateTests", targets: ["NotionGateTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "NotionGateLib",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "NotionGate",
            exclude: ["Server/main.swift", "App/NotionGateApp.swift", "App/Resources"]
        ),
        .executableTarget(
            name: "NotionGate",
            dependencies: ["NotionGateLib"],
            path: "NotionGate/App",
            sources: ["NotionGateApp.swift"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "NotionGateTests",
            dependencies: ["NotionGateLib",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "NotionGateTests"
        ),
    ]
)
