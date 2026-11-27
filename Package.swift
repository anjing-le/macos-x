// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "macos-x",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacOSX", targets: ["MacOSX"]), .executable(name: "FileActionsWorker", targets: ["FileActionsWorker"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "MenuBarVisibilityBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .target(name: "MacOSXCore"),
        .executableTarget(name: "FileActionsWorker", dependencies: ["MacOSXCore"]),
        .executableTarget(
            name: "MacOSX",
            dependencies: ["MacOSXCore", "MenuBarVisibilityBridge", .product(name: "Sparkle", package: "Sparkle")],
            // Historical proxy-drawer experiments remain for isolated regression
            // fixtures, but are not part of the native-menu-bar application.
            exclude: ["MenuBarShelf/MenuBarDrawer.swift", "MenuBarShelf/MenuBarDrawerInput.swift",
                      "MenuBarShelf/MenuBarCoveredInput.swift", "MenuBarShelf/MenuBarNativeInteraction.swift",
                      "MenuBarShelf/MenuBarLiveSession.swift", "MenuBarShelf/MenuBarLivePixels.swift",
                      "MenuBarShelf/MenuBarIconCapture.swift"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "MacOSXCoreTests", dependencies: ["MacOSXCore"])
    ]
)
