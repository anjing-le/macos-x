// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "macos-x",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacOSX", targets: ["MacOSX"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "MenuBarVisibilityBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .target(name: "MacOSXCore"),
        .executableTarget(
            name: "MacOSX",
            dependencies: ["MacOSXCore", "MenuBarVisibilityBridge", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "MacOSXCoreTests", dependencies: ["MacOSXCore"])
    ]
)
