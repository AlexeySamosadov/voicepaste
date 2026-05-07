// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoicePaste",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "VoicePaste",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources"
        )
    ]
)
