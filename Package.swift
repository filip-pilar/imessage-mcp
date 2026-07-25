// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iMessageMCP",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MessageMCPKit", targets: ["MessageMCPKit"]),
        .executable(name: "iMessageMCP", targets: ["iMessageMCP"]),
        .executable(name: "imessage-mcp", targets: ["imessage-mcp"]),
    ],
    targets: [
        .target(name: "MessageMCPKit"),
        .executableTarget(
            name: "iMessageMCP",
            dependencies: ["MessageMCPKit"]
        ),
        .executableTarget(
            name: "imessage-mcp",
            dependencies: ["MessageMCPKit"]
        ),
        .testTarget(
            name: "MessageMCPKitTests",
            dependencies: ["MessageMCPKit"]
        ),
    ]
)
