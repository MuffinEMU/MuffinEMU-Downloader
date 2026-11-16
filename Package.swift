// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WUDCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "WUDCore", targets: ["WUDCore"]),
    ],
    targets: [
        .target(
            name: "WUDCore",
            path: "Sources/WUDCore",
            resources: [
                .copy("Resources/title_db.json"),
                .copy("Resources/title_metadata.json"),
            ]
        ),
        .testTarget(name: "WUDCoreTests", dependencies: ["WUDCore"], path: "Tests/WUDCoreTests"),
    ]
)
