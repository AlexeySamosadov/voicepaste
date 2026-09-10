// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoicePaste",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.4"),
    ],
    targets: [
        // Tiny Objective-C helper so Swift can catch NSExceptions raised by
        // AVFAudio (installTap / engine start) instead of aborting the app.
        .target(
            name: "ObjCShim",
            path: "Sources/ObjCShim",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "VoicePaste",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "ObjCShim",
            ],
            path: "Sources",
            exclude: ["ObjCShim"]
        )
    ]
)
