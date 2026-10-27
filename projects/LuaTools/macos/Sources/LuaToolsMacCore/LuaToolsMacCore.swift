import Foundation
import Network
import CryptoKit
import Darwin

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
    public let filenamesEncrypted: Bool
    public let sizeOnDisk: UInt64
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
              bytes.count >= 16, bytes.count <= 64 * 1024 * 1024 else {
            throw LuaToolsError.invalidManifest
        }
        let metadata = try SteamManifestReader.read(bytes)
        guard metadata.depotID == UInt32(depot), metadata.gid == gid else { throw LuaToolsError.invalidManifest }
        self.depotID = UInt32(depot); self.manifestGID = gid; self.bytes = bytes; self.sourceName = name
        self.filenamesEncrypted = metadata.filenamesEncrypted; self.sizeOnDisk = metadata.sizeOnDisk
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
        return try installLuaData(appID: appID, contents: boundedData(source, maximum: 16 * 1024 * 1024))
    }
    private func installLuaData(appID: Int, contents: Data) throws -> LuaInstallResult {
        guard contents.count <= 16 * 1024 * 1024, String(data: contents, encoding: .utf8) != nil else { throw LuaToolsError.invalidRequest }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.stPlugin, withIntermediateDirectories: true)
        let destination = paths.stPlugin.appendingPathComponent("\(appID).lua")
        try PackageTransaction(paths: paths).apply([.init(relativePath: "config/stplug-in/\(appID).lua", data: contents)])
        return LuaInstallResult(appID: appID, luaURL: destination, manifests: 0)
    }
    public func installZip(appID: Int, zip: URL) throws -> LuaInstallResult {
        lock.lock(); defer { lock.unlock() }
        guard appID > 0, appID <= Int(UInt32.max), try regularFile(zip), zip.pathExtension.lowercased() == "zip" else { throw LuaToolsError.invalidRequest }
        return try installZipData(appID: appID, data: boundedData(zip, maximum: 256 * 1024 * 1024))
    }
    /// Windows sources may return a bare Lua instead of the advertised ZIP.
    public func installDownloaded(appID: Int, data: Data) throws -> LuaInstallResult {
        lock.lock(); defer { lock.unlock() }
        guard appID > 0, appID <= Int(UInt32.max), !data.isEmpty else { throw LuaToolsError.invalidRequest }
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) { return try installZipData(appID: appID, data: data) }
        return try installLuaData(appID: appID, contents: data)
    }
    private func installZipData(appID: Int, data: Data) throws -> LuaInstallResult {
        let archive = try ZipArchiveReader(data: data).entries()
        let luaFiles = archive.filter { URL(fileURLWithPath: $0.path).pathExtension.lowercased() == "lua" }
        let lua: ZipArchiveReader.Entry
        if luaFiles.count == 1 { lua = luaFiles[0] }
        else {
            let exact = luaFiles.filter { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent == "\(appID)" }
            guard exact.count == 1 else { throw exact.isEmpty ? LuaToolsError.missingLua : LuaToolsError.archiveConflict }
            lua = exact[0]
        }
        let luaData = lua.data
        guard luaData.count <= 16 * 1024 * 1024, String(data: luaData, encoding: .utf8) != nil else { throw LuaToolsError.invalidRequest }
        var manifests: [DepotManifest] = []
        var names: Set<String> = []
        for file in archive where URL(fileURLWithPath: file.path).pathExtension.lowercased() == "manifest" {
            let item = try DepotManifest(fileName: URL(fileURLWithPath: file.path).lastPathComponent, bytes: file.data)
            guard names.insert(item.fileName).inserted else { throw LuaToolsError.archiveConflict }
            manifests.append(item)
        }
        try FileManager.default.createDirectory(at: paths.stPlugin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.depotCache, withIntermediateDirectories: true)
        let luaDestination = paths.stPlugin.appendingPathComponent("\(appID).lua")
        let writes = [PackageTransaction.Write(relativePath: "config/stplug-in/\(appID).lua", data: luaData)] + manifests.map { .init(relativePath: "depotcache/\($0.fileName)", data: $0.bytes) }
        try PackageTransaction(paths: paths).apply(writes)
        return LuaInstallResult(appID: appID, luaURL: luaDestination, manifests: manifests.count)
    }
    /// Install standalone Steam depot manifests with the same identity checks
    /// and journal used for manifests received in a Lua package.
    public func installManifests(sources: [URL]) throws -> [DepotManifest] {
        lock.lock(); defer { lock.unlock() }
        guard !sources.isEmpty, sources.count <= 4096 else { throw LuaToolsError.invalidRequest }
        var names = Set<String>(), manifests: [DepotManifest] = []
        var total = 0
        for source in sources {
            let data = try boundedData(source, maximum: 64 * 1024 * 1024)
            total += data.count
            guard total <= 256 * 1024 * 1024 else { throw LuaToolsError.archiveTooLarge }
            let manifest = try DepotManifest(fileName: source.lastPathComponent, bytes: data)
            guard names.insert(manifest.fileName).inserted else { throw LuaToolsError.archiveConflict }
            manifests.append(manifest)
        }
        try FileManager.default.createDirectory(at: paths.stPlugin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.depotCache, withIntermediateDirectories: true)
        try PackageTransaction(paths: paths).apply(manifests.map { .init(relativePath: "depotcache/\($0.fileName)", data: $0.bytes) })
        return manifests
    }
    public func recoverPendingTransactions() throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: paths.userData.appendingPathComponent("config").path) else { return }
        try PackageTransaction(paths: paths).recover()
    }
    public func hasLua(appID: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return appID > 0 && FileManager.default.fileExists(atPath: paths.stPlugin.appendingPathComponent("\(appID).lua").path)
    }
    public func removeLua(appID: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard appID > 0, appID <= Int(UInt32.max) else { throw LuaToolsError.invalidRequest }
        guard FileManager.default.fileExists(atPath: paths.stPlugin.path) else { try recoverPendingTransactions(); return }
        try PackageTransaction(paths: paths).apply([
            .remove("config/stplug-in/\(appID).lua"),
            .remove("config/stplug-in/\(appID).lua.disabled")
        ])
    }
    private func regularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    private func boundedData(_ url: URL, maximum: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw LuaToolsError.unsafeArchive }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= maximum else { throw LuaToolsError.unsafeArchive }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try file.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw LuaToolsError.archiveTooLarge }
        return data
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
        case .transactionFailed(let detail): "No se pudo completar la transacción: \(detail)"
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
