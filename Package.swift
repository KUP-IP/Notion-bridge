// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeeprBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KeeprServer", targets: ["KeeprServer"]),
        .executable(name: "KeeprApp", targets: ["KeeprApp"]),
        .executable(name: "KeeprTests", targets: ["KeeprTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .target(
            name: "KeeprLib",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Keepr",
            exclude: ["Server/main.swift", "App/KeeprApp.swift"]
        ),
        .executableTarget(
            name: "KeeprServer",
            dependencies: ["KeeprLib",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Keepr/Server",
            sources: ["main.swift"]
        ),
        .executableTarget(
            name: "KeeprApp",
            dependencies: ["KeeprLib"],
            path: "Keepr/App",
            sources: ["KeeprApp.swift"]
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
