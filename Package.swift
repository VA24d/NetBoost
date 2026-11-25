// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetBoost",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NetBoostCore", targets: ["NetBoostCore"]),
        .executable(name: "NetBoostApp", targets: ["NetBoostApp"]),
        .executable(name: "NetBoostHelper", targets: ["NetBoostHelper"])
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
        .executableTarget(
            name: "NetBoostHelper",
            dependencies: ["NetBoostCore"],
            path: "Sources/NetBoostHelper"
        ),
        .testTarget(
            name: "NetBoostTests",
            dependencies: ["NetBoostCore", "NetBoostApp"],
            path: "Tests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
