// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MCPKit",
    platforms: [.macOS(.v14), .iOS(.v17), .macCatalyst(.v17)],
    products: [
        .library(name: "MCPKit", targets: ["MCPKit"]),
        .executable(name: "apple-home-mcp-bridge", targets: ["apple-home-mcp-bridge"]),
    ],
    targets: [
        .target(name: "MCPKit"),
        .executableTarget(name: "apple-home-mcp-bridge", dependencies: ["MCPKit"]),
        .testTarget(name: "MCPKitTests", dependencies: ["MCPKit"]),
    ]
)
