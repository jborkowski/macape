// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macape",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacapeCore", targets: ["MacapeCore"]),
        .executable(name: "macape", targets: ["macape"]),
        .executable(name: "macape-bar", targets: ["macape-bar"]),
    ],
    targets: [
        .target(
            name: "MacapeCore",
            path: "Sources/MacapeCore"
        ),
        .executableTarget(
            name: "macape",
            dependencies: ["MacapeCore"],
            path: "Sources/macape"
        ),
        .executableTarget(
            name: "macape-bar",
            dependencies: ["MacapeCore"],
            path: "Sources/macape-bar"
        ),
        .testTarget(
            name: "MacapeCoreTests",
            dependencies: ["MacapeCore"],
            path: "Tests/MacapeCoreTests"
        ),
    ]
)
