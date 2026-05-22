// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macape",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "macape",
            path: "Sources/macape"
        )
    ]
)
