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
        .library(name: "WispLlama", targets: ["WispLlama"]),
        .library(name: "WispUI", targets: ["WispUI"]),
        .executable(name: "wisp", targets: ["WispCLI"])
    ],
    targets: [
        .target(
            name: "WispCore",
            path: "Sources/WispCore"
        ),
        .target(
            name: "WispLlama",
            dependencies: [
                "WispCore",
                "LlamaFramework"
            ],
            path: "Sources/WispLlama",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal")
            ]
        ),
        .target(
            name: "WispUI",
            dependencies: ["WispCore"],
            path: "Sources/WispUI"
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
        ),
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b8981/llama-b8981-xcframework.zip",
            checksum: "3c0ba1b99c8cb04fa78b495ab63158f3bad7add3e49e7bd961b2d3ef3f178454"
        )
    ]
)
