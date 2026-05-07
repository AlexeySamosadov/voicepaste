// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TempMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TempMonitor",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
