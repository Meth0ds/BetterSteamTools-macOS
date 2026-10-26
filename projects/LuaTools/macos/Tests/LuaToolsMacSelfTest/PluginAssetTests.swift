import Foundation
import LuaToolsMacCore

func testPluginAssets(root: URL) throws {
    let plugin = root.appendingPathComponent("plugin")
    let assets = plugin.appendingPathComponent("public")
    try FileManager.default.createDirectory(at: assets.appendingPathComponent("themes"), withIntermediateDirectories: true)
    try "window.__LuaToolsInjected = true;".write(to: assets.appendingPathComponent("luatools.js"), atomically: true, encoding: .utf8)
    try "body { color: red }".write(to: assets.appendingPathComponent("steamdb-webkit.css"), atomically: true, encoding: .utf8)
    let metadata = assets.appendingPathComponent("themes/themes.json")
    try #"[{"value":"original","name":"Original"}]"#.write(to: metadata, atomically: true, encoding: .utf8)
    try ":root { --theme: 1 }".write(to: assets.appendingPathComponent("themes/original.css"), atomically: true, encoding: .utf8)
    let bundle = try PluginFrontend(pluginDirectory: plugin)
    try check(bundle.script.hasPrefix("window.__LuaToolsMacAssets = "), "local assets precede frontend")
    try check(bundle.script.contains("body { color: red }") && bundle.script.contains(":root { --theme: 1 }"), "CSS travels over CDP instead of resolving relative to Steam store")
    try #"[{"value":"../../outside"}]"#.write(to: metadata, atomically: true, encoding: .utf8)
    var rejected = false
    do { _ = try PluginFrontend(pluginDirectory: plugin) } catch { rejected = true }
    try check(rejected, "asset names cannot traverse directories")
    let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let actual = try PluginFrontend(pluginDirectory: checkout.appendingPathComponent("plugin-macos"))
    try check(actual.script.contains("catppuccin") && actual.script.contains("LuaTools"), "real packaged plugin assets compose successfully")
}
