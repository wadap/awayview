// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AwayView",
    defaultLocalization: "en",
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
            resources: [.process("Resources")],
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
