import Foundation
import Network
import CryptoKit

public struct SteamMacPaths: Sendable {
    public let steamApp: URL
    public let userData: URL
    public init(steamApp: URL = URL(fileURLWithPath: "/Applications/Steam.app"), userData: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Steam")) {
        self.steamApp = steamApp
        self.userData = userData
    }
    public static var detected: SteamMacPaths {
        let env = ProcessInfo.processInfo.environment["LUA_TOOLS_STEAM_APP_PATH"].map(URL.init(fileURLWithPath:))
        let app = [env, URL(fileURLWithPath: "/Applications/Steam.app"), URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Steam.app")].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) } ?? URL(fileURLWithPath: "/Applications/Steam.app")
        return SteamMacPaths(steamApp: app)
    }
    public var infoPlist: URL { steamApp.appendingPathComponent("Contents/Info.plist") }
    public var stPlugin: URL { userData.appendingPathComponent("config/stplug-in", isDirectory: true) }
    public var depotCache: URL { userData.appendingPathComponent("depotcache", isDirectory: true) }
    public var libraryFolders: URL { userData.appendingPathComponent("steamapps/libraryfolders.vdf") }
}

public enum SteamVDF {
    private static let pairPattern = #""([^"\\]*(?:\\.[^"\\]*)*)"\s+"([^"\\]*(?:\\.[^"\\]*)*)""#
    public static func value(_ key: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pairPattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let k = Range(match.range(at: 1), in: text), let v = Range(match.range(at: 2), in: text) else { continue }
            if text[k].lowercased() == key.lowercased() { return String(text[v]).replacingOccurrences(of: "\\\\", with: "\\") }
        }
        return nil
    }
    public static func libraries(paths: SteamMacPaths) -> [URL] {
        var result = [paths.userData]
        guard let text = try? String(contentsOf: paths.libraryFolders, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #""path"\s+"((?:\\.|[^"])*)""#) else { return result }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: text) else { return }
            let path = String(text[r]).replacingOccurrences(of: "\\\\", with: "\\")
            let url = URL(fileURLWithPath: path)
            if !result.contains(url) { result.append(url) }
        }
        return result
    }
}

public struct LuaInstallResult: Sendable, Equatable {
    public let appID: Int
    public let luaURL: URL
    public let manifests: Int
}

public struct DepotManifest: Sendable, Equatable {
    public let depotID: UInt32
    public let manifestGID: UInt64
    public let bytes: Data
    public let sourceName: String
    public var fileName: String { "\(depotID)_\(manifestGID).manifest" }
    public init(fileName: String, bytes: Data) throws {
        let name = URL(fileURLWithPath: fileName).lastPathComponent
        let pattern = try NSRegularExpression(pattern: #"^([1-9][0-9]{0,9})_([1-9][0-9]{0,19})\.manifest$"#)
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = pattern.firstMatch(in: name, range: range),
              let depotRange = Range(match.range(at: 1), in: name),
              let gidRange = Range(match.range(at: 2), in: name),
              let depot = UInt64(name[depotRange]), depot > 0, depot <= UInt64(UInt32.max),
              let gid = UInt64(name[gidRange]), gid > 0,
              bytes.count >= 16, bytes.count <= 64 * 1024 * 1024,
              bytes.prefix(4).elementsEqual([0xD0, 0x17, 0xF6, 0x71]), bytes.suffix(4).elementsEqual([0xAB, 0x15, 0xC4, 0x32]) else {
            throw LuaToolsError.invalidManifest
        }
        self.depotID = UInt32(depot); self.manifestGID = gid; self.bytes = bytes; self.sourceName = name
    }
}

public final class LuaInstaller: @unchecked Sendable {
    public let paths: SteamMacPaths
    private let lock = NSRecursiveLock()
    public init(paths: SteamMacPaths = .detected) { self.paths = paths }
    public func installLua(appID: Int, source: URL) throws -> LuaInstallResult {
        lock.lock(); defer { lock.unlock() }
        guard appID > 0, appID <= Int(UInt32.max) else { throw LuaToolsError.invalidRequest }
        guard try regularFile(source), source.pathExtension.lowercased() == "lua" else { throw LuaToolsError.invalidRequest }
        let contents = try boundedData(source, maximum: 16 * 1024 * 1024)
        guard contents.count <= 16 * 1024 * 1024, String(data: contents, encoding: .utf8) != nil else { throw LuaToolsError.invalidRequest }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.stPlugin, withIntermediateDirectories: true)
        let destination = paths.stPlugin.appendingPathComponent("\(appID).lua")
        try atomicReplace(contents, at: destination)
        return LuaInstallResult(appID: appID, luaURL: destination, manifests: 0)
    }
    public func installZip(appID: Int, zip: URL) throws -> LuaInstallResult {
        lock.lock(); defer { lock.unlock() }
        guard appID > 0, appID <= Int(UInt32.max), try regularFile(zip), zip.pathExtension.lowercased() == "zip" else { throw LuaToolsError.invalidRequest }
        guard let archiveSize = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize, archiveSize <= 256 * 1024 * 1024 else { throw LuaToolsError.archiveTooLarge }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("luatools-\(UUID().uuidString)")
        let extraction = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = try Shell.run("/usr/bin/unzip", ["-Z1", zip.path])
        try validateArchiveListing(listing)
        try Shell.run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", extraction.path])
        try validateExtractedTree(extraction)
        let files = try regularFiles(in: extraction)
        let luaFiles = files.filter { $0.pathExtension.lowercased() == "lua" }
        let lua: URL
        if luaFiles.count == 1 { lua = luaFiles[0] }
        else if let exact = luaFiles.first(where: { $0.deletingPathExtension().lastPathComponent == "\(appID)" }) { lua = exact }
        else { throw LuaToolsError.missingLua }
        let luaData = try boundedData(lua, maximum: 16 * 1024 * 1024)
        guard String(data: luaData, encoding: .utf8) != nil else { throw LuaToolsError.invalidRequest }
        var manifests: [DepotManifest] = []
        var names: Set<String> = []
        for file in files where file.pathExtension.lowercased() == "manifest" {
            let item = try DepotManifest(fileName: file.lastPathComponent, bytes: boundedData(file, maximum: 64 * 1024 * 1024))
            guard names.insert(item.fileName).inserted else { throw LuaToolsError.archiveConflict }
            manifests.append(item)
        }
        try FileManager.default.createDirectory(at: paths.stPlugin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.depotCache, withIntermediateDirectories: true)
        let luaDestination = paths.stPlugin.appendingPathComponent("\(appID).lua")
        let destinations = [(luaDestination, luaData)] + manifests.map { (paths.depotCache.appendingPathComponent($0.fileName), $0.bytes) }
        var old: [(URL, Data?)] = []
        do {
            for (destination, _) in destinations {
                guard try noSymlink(destination, within: destination.deletingLastPathComponent()) else { throw LuaToolsError.unsafeArchive }
                do { old.append((destination, try regularExistingData(destination))) }
                catch { throw LuaToolsError.transactionFailed("inspect \(destination.path): \(error.localizedDescription)") }
            }
            for (destination, data) in destinations {
                do { try atomicReplace(data, at: destination) }
                catch { throw LuaToolsError.transactionFailed("\(destination.path): \(error.localizedDescription)") }
            }
        } catch {
            for (index, (destination, previous)) in old.enumerated() {
                if let previous { try? atomicReplace(previous, at: destination) }
                else { try? FileManager.default.removeItem(at: destination) }
                _ = index
            }
            throw LuaToolsError.transactionFailed(String(describing: error))
        }
        return LuaInstallResult(appID: appID, luaURL: luaDestination, manifests: manifests.count)
    }
    public func hasLua(appID: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return appID > 0 && FileManager.default.fileExists(atPath: paths.stPlugin.appendingPathComponent("\(appID).lua").path)
    }
    public func removeLua(appID: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard appID > 0, appID <= Int(UInt32.max) else { throw LuaToolsError.invalidRequest }
        let url = paths.stPlugin.appendingPathComponent("\(appID).lua")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func regularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    private func boundedData(_ url: URL, maximum: Int) throws -> Data {
        guard try regularFile(url) else { throw LuaToolsError.unsafeArchive }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw LuaToolsError.archiveTooLarge }
        return data
    }
    private func regularExistingData(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try boundedData(url, maximum: 64 * 1024 * 1024)
    }
    private func atomicReplace(_ data: Data, at destination: URL) throws {
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            throw LuaToolsError.transactionFailed("destination directory missing: \(destination.deletingLastPathComponent().path)")
        }
        try data.write(to: destination, options: .atomic)
    }
    private func noSymlink(_ url: URL, within root: URL) throws -> Bool {
        var cursor = url
        while cursor.path.hasPrefix(root.path) {
            if FileManager.default.fileExists(atPath: cursor.path) {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true { return false }
            }
            if cursor == root { break }
            cursor.deleteLastPathComponent()
        }
        return true
    }
    private func validateArchiveListing(_ listing: String) throws {
        var total = 0
        for raw in listing.split(whereSeparator: \.isNewline) {
            let item = String(raw).replacingOccurrences(of: "\\", with: "/")
            guard !item.isEmpty, item.utf8.count <= 512, !item.hasPrefix("/"), !item.split(separator: "/").contains(".."), !item.contains("\0") else { throw LuaToolsError.unsafeArchive }
            total += item.utf8.count
            guard total <= 1_048_576 else { throw LuaToolsError.archiveTooLarge }
        }
    }
    private func validateExtractedTree(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw LuaToolsError.unsafeArchive }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LuaToolsError.unsafeArchive }
        }
    }
    private func regularFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw LuaToolsError.unsafeArchive }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw LuaToolsError.unsafeArchive }
            if values.isRegularFile == true { result.append(url) }
        }
        return result
    }
}

public enum LuaToolsError: LocalizedError {
    case missingLua
    case invalidRequest
    case missingInstaller
    case invalidManifest
    case unsafeArchive
    case archiveConflict
    case archiveTooLarge
    case transactionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .missingLua: "El paquete no contiene ningún archivo Lua."
        case .invalidRequest: "Petición no válida."
        case .missingInstaller: "El paquete LuaTools no incluye un instalador BetterSteamTools validado."
        case .invalidManifest: "El archivo no es un manifiesto de depot válido."
        case .unsafeArchive: "El ZIP contiene rutas, enlaces o archivos no permitidos."
        case .archiveConflict: "El paquete contiene nombres de depot duplicados o incompatibles."
        case .archiveTooLarge: "El paquete supera el tamaño máximo permitido."
        case .transactionFailed(let detail): "No se pudo instalar el paquete y se restauró el estado anterior: \(detail)"
        }
    }
}

/// Delegates every Steam mutation to the same installer used by the CLI.
public struct SteamActivation: Sendable {
    public let paths: SteamMacPaths
    public let helper: URL?
    public init(paths: SteamMacPaths = .detected, helper: URL? = Bundle.main.url(forResource: "bst-macos", withExtension: nil)) {
        self.paths = paths; self.helper = helper
    }
    public func activate(dylib: URL, manifest: URL, dryRun: Bool = false) throws {
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path) else { throw LuaToolsError.missingInstaller }
        var arguments = ["install", "--dylib", dylib.path, "--manifest", manifest.path]
        if dryRun { arguments.append("--dry-run") }
        try Shell.run(helper.path, arguments, environment: ["BST_STEAM_APP_PATH": paths.steamApp.path])
    }
}

public struct LaunchAgentInstaller: Sendable {
    public init() {}
    public func install(executable: URL) throws -> URL {
        let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/com.luatools.macos.plist")
        let dict: [String: Any] = ["Label": "com.luatools.macos", "ProgramArguments": [executable.path, "--background"], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: file, options: .atomic)
        return file
    }
}

public struct PluginInstaller: Sendable {
    public let destination: URL
    public init(destination: URL? = nil) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let override = ProcessInfo.processInfo.environment["LUA_TOOLS_PLUGIN_DIR"].map { URL(fileURLWithPath: $0) }
        self.destination = destination ?? override ?? home.appendingPathComponent("Library/Application Support/LuaToolsMac/plugin", isDirectory: true)
    }
    public func install(zip: URL, expectedSHA256: String? = nil) throws {
        if let expectedSHA256, sha256(url: zip) != expectedSHA256.lowercased() { throw LuaToolsError.invalidRequest }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Shell.run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", destination.path])
    }
    private func sha256(url: URL) -> String { (try? SHA256.hash(data: Data(contentsOf: url))).map { $0.map { String(format: "%02x", $0) }.joined() } ?? "" }
}


public enum Shell {
    @discardableResult public static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, supplied in supplied }
        let output = Pipe(); let error = Pipe(); process.standardOutput = output; process.standardError = error
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LuaToolsError.invalidRequest }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
