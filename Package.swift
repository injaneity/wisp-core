// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wisp-core",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "wisp-chat", targets: ["WispChat"])
    ],
    targets: [
        .executableTarget(
            name: "WispChat",
            path: "Sources/WispChat"
        )
    ]
)
