// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LuaToolsMac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LuaToolsMacCore", targets: ["LuaToolsMacCore"]),
        .executable(name: "LuaToolsMac", targets: ["LuaToolsMac"]),
        .executable(name: "LuaToolsMacSelfTest", targets: ["LuaToolsMacSelfTest"]),
        .executable(name: "LuaToolsCDPSelfTest", targets: ["LuaToolsCDPSelfTest"]),
    ],
    targets: [
        .target(name: "NativeProcessInspection"),
        .target(name: "NativeZip", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "LuaToolsMacCore", dependencies: ["NativeProcessInspection", "NativeZip"], resources: [.copy("Resources/CDPBridge.js")]),
        .executableTarget(name: "LuaToolsMac", dependencies: ["LuaToolsMacCore"]),
        .executableTarget(name: "LuaToolsMacSelfTest", dependencies: ["LuaToolsMacCore"], path: "Tests/LuaToolsMacSelfTest"),
        .executableTarget(name: "LuaToolsCDPSelfTest", dependencies: ["LuaToolsMacCore"], path: "Tests/LuaToolsCDPSelfTest"),
    ]
)
