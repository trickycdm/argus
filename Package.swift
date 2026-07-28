// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Argus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Argus",
            path: "Sources/Argus",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ArgusTests",
            dependencies: ["Argus"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
