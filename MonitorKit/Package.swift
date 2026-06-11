// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonitorKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "MonitorKit", targets: ["MonitorKit"]),
    ],
    targets: [
        .target(name: "MonitorKit"),
        .testTarget(name: "MonitorKitTests", dependencies: ["MonitorKit"]),
    ]
)
