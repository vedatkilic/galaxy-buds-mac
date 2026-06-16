// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BudsApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BudsApp",
            path: "Sources",
            resources: [.process("Resources")]
        )
    ]
)
