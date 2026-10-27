import Foundation

/// Both transports deliver the same local assets. Relative stylesheet URLs would
/// otherwise resolve against store.steampowered.com when CDP executes the frontend.
public struct PluginFrontend: Sendable {
    public let script: String
    public static func validateBridgeResource() throws {
        guard let bridge = Bundle.module.url(forResource: "CDPBridge", withExtension: "js"),
              !(try text(bridge, limit: 1_048_576)).isEmpty else { throw LuaToolsError.invalidRequest }
    }
    public init(pluginDirectory: URL) throws {
        let root = pluginDirectory.appendingPathComponent("public", isDirectory: true)
        let javascript = try Self.text(root.appendingPathComponent("luatools.js"), limit: 1_048_576)
        let base = try Self.text(root.appendingPathComponent("steamdb-webkit.css"), limit: 262_144)
        let themes = try JSONDecoder().decode(BridgeJSON.self, from: Data(Self.text(root.appendingPathComponent("themes/themes.json"), limit: 65_536).utf8))
        guard case .array(let entries) = themes, !entries.isEmpty, entries.count <= 64 else { throw LuaToolsError.invalidRequest }
        var css: [String: BridgeJSON] = [:]
        for entry in entries {
            guard let key = entry["value"]?.string, !key.isEmpty, key.utf8.count <= 48,
                  key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), css[key] == nil else { throw LuaToolsError.invalidRequest }
            css[key] = .string(try Self.text(root.appendingPathComponent("themes/\(key).css"), limit: 131_072))
        }
        let assets = BridgeJSON.object(["version": .number(1), "baseCSS": .string(base), "themes": themes, "themeCSS": .object(css)])
        self.script = "window.__LuaToolsMacAssets = \(try assets.encoded());\n" + javascript
        guard self.script.utf8.count <= 1_500_000 else { throw LuaToolsError.invalidRequest }
    }
    private static func text(_ url: URL, limit: Int) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= limit else { throw LuaToolsError.invalidRequest }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, let text = String(data: data, encoding: .utf8) else { throw LuaToolsError.invalidRequest }
        return text
    }
}
