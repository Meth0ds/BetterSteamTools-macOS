// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterSteamToolsMac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BetterSteamToolsMacCore", targets: ["BetterSteamToolsMacCore"]),
        .executable(name: "bst-macos", targets: ["bst-macos"]),
        .executable(name: "bst-macos-selftest", targets: ["bst-macos-selftest"]),
    ],
    targets: [
        .target(name: "BSTBuildApproval"),
        .target(name: "BetterSteamToolsMacCore", dependencies: ["BSTBuildApproval"]),
        .executableTarget(name: "bst-macos", dependencies: ["BetterSteamToolsMacCore"]),
        .executableTarget(name: "bst-macos-selftest", dependencies: ["BetterSteamToolsMacCore", "BSTBuildApproval"], path: "Tests/BetterSteamToolsMacSelfTest"),
    ]
)
