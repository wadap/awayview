// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenshareRes",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ScreenshareRes",
            path: "Sources/ScreenshareRes",
            linkerSettings: [
                .linkedFramework("ColorSync"),  // CGDisplayCreateUUIDFromDisplayID の実体
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "ScreenshareResTests",
            dependencies: ["ScreenshareRes"],
            path: "Tests/ScreenshareResTests"
        ),
    ]
)
