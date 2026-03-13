// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KeeprBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "KeeprServer", targets: ["KeeprServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "KeeprServer",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Keepr/Server"
        ),
        .testTarget(
            name: "KeeprTests",
            dependencies: ["KeeprServer"],
            path: "KeeprTests"
        ),
    ]
)
