// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetBoost",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NetBoostCore", targets: ["NetBoostCore"]),
        .executable(name: "NetBoostApp", targets: ["NetBoostApp"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "NetBoostCore",
            dependencies: [],
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "NetBoostApp",
            dependencies: ["NetBoostCore"],
            path: "Sources/NetBoostApp"
        ),
        .testTarget(
            name: "NetBoostTests",
            dependencies: ["NetBoostCore"],
            path: "Tests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
