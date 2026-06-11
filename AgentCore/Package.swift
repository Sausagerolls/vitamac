// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .executable(name: "montop", targets: ["montop"]),
        .executable(name: "MonitorHelper", targets: ["MonitorHelper"]),
    ],
    dependencies: [
        .package(path: "../MonitorKit"),
    ],
    targets: [
        .target(
            name: "AgentCore",
            dependencies: [
                .product(name: "MonitorKit", package: "MonitorKit"),
            ]
        ),
        .executableTarget(
            name: "montop",
            dependencies: ["AgentCore"]
        ),
        .executableTarget(
            name: "MonitorHelper",
            dependencies: ["AgentCore"]
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"]
        ),
    ]
)
