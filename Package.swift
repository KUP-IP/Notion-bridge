// swift-tools-version: 6.0
// PKT-318: Added swift-nio for SSE transport on :9700
import PackageDescription

let package = Package(
    name: "KeeprBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KeeprApp", targets: ["KeeprApp"]),
        .executable(name: "KeeprTests", targets: ["KeeprTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "KeeprLib",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Keepr",
            exclude: ["Server/main.swift", "App/KeeprApp.swift", "App/Resources"]
        ),
        .executableTarget(
            name: "KeeprApp",
            dependencies: ["KeeprLib"],
            path: "Keepr/App",
            sources: ["KeeprApp.swift"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "KeeprTests",
            dependencies: ["KeeprLib",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "KeeprTests"
        ),
    ]
)
