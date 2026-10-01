// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacMonitor",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
