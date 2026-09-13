// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BoseHeadphonesControlTests",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "BoseTestSupport",
            path: "Sources/BoseTestSupport"
        ),
        .testTarget(
            name: "BoseHeadphonesControlTests",
            dependencies: ["BoseTestSupport"],
            path: "Tests/BoseHeadphonesControlTests"
        )
    ]
)
