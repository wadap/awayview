// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenshareRes",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CShim",
            path: "Sources/CShim"
        ),
        .executableTarget(
            name: "ScreenshareRes",
            dependencies: ["CShim"],
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
