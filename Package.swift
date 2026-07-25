// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AwayView",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CShim",
            path: "Sources/CShim"
        ),
        .executableTarget(
            name: "AwayView",
            dependencies: ["CShim"],
            path: "Sources/AwayView",
            linkerSettings: [
                .linkedFramework("ColorSync"),  // CGDisplayCreateUUIDFromDisplayID の実体
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "AwayViewTests",
            dependencies: ["AwayView"],
            path: "Tests/AwayViewTests"
        ),
    ]
)
