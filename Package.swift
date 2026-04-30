// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wisp",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "WispCore", targets: ["WispCore"]),
        .executable(name: "wisp", targets: ["WispCLI"])
    ],
    targets: [
        .target(
            name: "WispCore",
            path: "Sources/WispCore"
        ),
        .executableTarget(
            name: "WispCLI",
            dependencies: ["WispCore"],
            path: "Sources/WispCLI"
        ),
        .testTarget(
            name: "WispCoreTests",
            dependencies: ["WispCore"],
            path: "Tests/WispCoreTests"
        )
    ]
)
