// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wisp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "wisp", targets: ["Wisp"])
    ],
    targets: [
        .executableTarget(
            name: "Wisp",
            path: "src"
        )
    ]
)
