// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultiZap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MultiZap",
            path: "Sources/MultiZap"
        )
    ]
)
