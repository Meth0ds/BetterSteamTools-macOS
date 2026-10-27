import Foundation
import CryptoKit
import Darwin

/// Installs a validated plugin directory by an atomic swap. The journal makes
/// interrupted install, rollback and uninstall operations recoverable.
public struct PluginInstaller {
    private struct Artifact: Codable, Equatable { let treeHash: String; let archiveHash: String; let version: String }
    private struct Receipt: Codable { let version: Int; let current: Artifact; let previous: Artifact? }
    private struct Journal: Codable { let version: Int; let action: String; var phase: String; let before: Artifact?; var after: Artifact?; let previous: Artifact? }
    public let destination: URL
    private let bundled: URL?
    private let parent: URL
    private let state: URL
    private let stage: URL
    private let previous: URL
    private let checkpoint: ((Int) -> Void)?
    private let applicationVersion = [1, 0, 0]

    public init(destination: URL? = nil) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let override = ProcessInfo.processInfo.environment["LUA_TOOLS_PLUGIN_DIR"].map { URL(fileURLWithPath: $0) }
        self.init(destination: destination ?? override ?? home.appendingPathComponent("Library/Application Support/LuaToolsMac/plugin", isDirectory: true),
                  bundledDirectory: Bundle.main.resourceURL?.appendingPathComponent("plugin-macos", isDirectory: true), checkpoint: nil)
    }
    @_spi(Testing) public init(destination: URL, bundledDirectory: URL?, checkpoint: ((Int) -> Void)?) {
        self.destination = destination.standardizedFileURL; self.bundled = bundledDirectory
        parent = self.destination.deletingLastPathComponent()
        let digest = SHA256.hash(data: Data(self.destination.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        state = parent.appendingPathComponent(".luatools-plugin-state-\(digest)", isDirectory: true)
        stage = parent.appendingPathComponent(".luatools-plugin-stage-\(digest)", isDirectory: true)
        previous = parent.appendingPathComponent(".luatools-plugin-previous-\(digest)", isDirectory: true)
        self.checkpoint = checkpoint
    }

    public func resolveActiveDirectory() throws -> URL? {
        try locked {
            try recoverLocked()
            let receipt = try readReceipt()
            if let receipt {
                guard try treeHash(destination) == receipt.current.treeHash else { throw failure("El plugin instalado cambió fuera de LuaTools") }
                return destination
            }
            guard try treeHash(destination) == nil else { throw failure("Existe un plugin sin registro de instalación; se conservará") }
            if try exists(state.appendingPathComponent("disabled")) { return nil }
            if let bundled, (try? PluginFrontend(pluginDirectory: bundled)) != nil { return bundled }
            return nil
        }
    }
    public func install(zip: URL, expectedSHA256: String? = nil) throws {
        let data = try readFile(zip, limit: 256 * 1024 * 1024)
        let archiveHash = hash(data)
        if let expectedSHA256 {
            guard expectedSHA256.count == 64, expectedSHA256.allSatisfy({ $0.isHexDigit }), archiveHash == expectedSHA256.lowercased() else { throw LuaToolsError.invalidRequest }
        }
        let entries = try ZipArchiveReader(data: data, maxEntry: 16 * 1024 * 1024, maxTotal: 64 * 1024 * 1024, maxEntries: 2048).entries()
        let manifest = try validateManifest(entries)
        try locked {
            try recoverLocked()
            let receipt = try readReceipt()
            try validateState(receipt)
            guard try !exists(stage) else { throw failure("La carpeta temporal del plugin ya existe") }
            var journal = Journal(version: 1, action: "install", phase: "staging", before: receipt?.current, after: nil, previous: receipt?.previous)
            try writeJournal(journal); checkpoint?(0)
            do {
                guard mkdir(stage.path, mode_t(0o700)) == 0 else { throw posix("create stage", stage) }
                try syncDirectory(parent)
                var names = Set<String>()
                for entry in entries {
                    guard names.insert(entry.path.lowercased()).inserted else { throw LuaToolsError.archiveConflict }
                    let output = stage.appendingPathComponent(entry.path)
                    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try atomicWrite(entry.data, to: output)
                }
                _ = try PluginFrontend(pluginDirectory: stage)
                guard let tree = try treeHash(stage) else { throw failure("No se pudo validar el plugin preparado") }
                if tree == receipt?.current.treeHash {
                    try removeDirectoryIfPresent(stage)
                    try removeFile(state.appendingPathComponent("journal.json"))
                    return
                }
                journal.after = Artifact(treeHash: tree, archiveHash: archiveHash, version: manifest)
                journal.phase = "prepared"; try writeJournal(journal); checkpoint?(1)
                try validateState(receipt)
                if receipt == nil { try renameDirectory(stage, destination) }
                else { try swap(destination, stage) }
                checkpoint?(2)
                journal.phase = "committed"; try writeJournal(journal); checkpoint?(3)
                try finish(journal); checkpoint?(6)
            } catch {
                do { try recoverLocked() } catch { throw failure("No se pudo recuperar la actualización del plugin: \(error.localizedDescription)") }
                throw error
            }
        }
    }
    public func rollback() throws {
        try locked {
            try recoverLocked()
            guard let receipt = try readReceipt(), let prior = receipt.previous else { throw failure("No hay una versión anterior del plugin") }
            try validateState(receipt)
            var journal = Journal(version: 1, action: "rollback", phase: "prepared", before: receipt.current, after: prior, previous: prior)
            try writeJournal(journal); checkpoint?(1)
            do {
                try swap(destination, previous); checkpoint?(2)
                journal.phase = "committed"; try writeJournal(journal); checkpoint?(3)
                try finish(journal); checkpoint?(6)
            } catch {
                do { try recoverLocked() } catch { throw failure("No se pudo recuperar el rollback: \(error.localizedDescription)") }
                throw error
            }
        }
    }
    public func uninstall() throws {
        try locked {
            try recoverLocked()
            let receipt = try readReceipt()
            try validateState(receipt)
            guard let receipt else { try atomicWrite(Data("disabled\n".utf8), to: state.appendingPathComponent("disabled")); return }
            guard try !exists(stage) else { throw failure("La carpeta temporal del plugin ya existe") }
            var journal = Journal(version: 1, action: "uninstall", phase: "prepared", before: receipt.current, after: nil, previous: receipt.previous)
            try writeJournal(journal); checkpoint?(1)
            do {
                try renameDirectory(destination, stage); checkpoint?(2)
                journal.phase = "committed"; try writeJournal(journal); checkpoint?(3)
                try finish(journal); checkpoint?(6)
            } catch {
                do { try recoverLocked() } catch { throw failure("No se pudo recuperar la desinstalación: \(error.localizedDescription)") }
                throw error
            }
        }
    }
    public func recover() throws { try locked { try recoverLocked() } }

    private func recoverLocked() throws {
        guard let journal = try read(Journal.self, from: state.appendingPathComponent("journal.json")) else {
            guard try !exists(stage) else { throw failure("Hay una carpeta temporal del plugin sin registro") }
            return
        }
        guard journal.version == 1, ["install", "rollback", "uninstall"].contains(journal.action), ["staging", "prepared", "committed"].contains(journal.phase) else { throw failure("Registro del plugin inválido") }
        if journal.phase == "staging" {
            guard journal.action == "install" else { throw failure("Registro del plugin inválido") }
            try removeDirectoryIfPresent(stage); try removeFile(state.appendingPathComponent("journal.json")); return
        }
        if journal.phase == "committed" { try finish(journal); return }
        let current = try treeHash(destination), staged = try treeHash(stage), prior = try treeHash(previous)
        switch journal.action {
        case "install":
            guard let after = journal.after else { throw failure("Registro del plugin incompleto") }
            if let before = journal.before {
                guard prior == journal.previous?.treeHash else { throw failure("La versión anterior del plugin cambió") }
                if current == after.treeHash && staged == before.treeHash { try swap(destination, stage) }
                else if current != before.treeHash || staged != after.treeHash { throw failure("El plugin cambió durante la recuperación") }
            } else {
                guard prior == nil else { throw failure("Existe una versión anterior sin registro") }
                if current == after.treeHash && staged == nil { try renameDirectory(destination, stage) }
                else if current != nil || staged != after.treeHash { throw failure("El plugin cambió durante la recuperación") }
            }
            try removeDirectoryIfPresent(stage)
        case "rollback":
            guard let before = journal.before, let after = journal.after, staged == nil else { throw failure("Registro del rollback inválido") }
            if current == after.treeHash && prior == before.treeHash { try swap(destination, previous) }
            else if current != before.treeHash || prior != after.treeHash { throw failure("El plugin cambió durante la recuperación") }
        case "uninstall":
            guard let before = journal.before, prior == journal.previous?.treeHash else { throw failure("Registro de desinstalación inválido") }
            if current == nil && staged == before.treeHash { try renameDirectory(stage, destination) }
            else if current != before.treeHash || staged != nil { throw failure("El plugin cambió durante la recuperación") }
        default: throw failure("Operación del plugin desconocida")
        }
        try removeFile(state.appendingPathComponent("journal.json"))
    }
    private func finish(_ journal: Journal) throws {
        switch journal.action {
        case "install":
            guard let after = journal.after, try treeHash(destination) == after.treeHash else { throw failure("El plugin nuevo cambió después de instalarse") }
            if let before = journal.before {
                let priorHash = try treeHash(previous), stageHash = try treeHash(stage)
                if priorHash != before.treeHash {
                    guard stageHash == before.treeHash, priorHash == journal.previous?.treeHash else { throw failure("No se pudo conservar la versión anterior") }
                    if priorHash == nil { try renameDirectory(stage, previous) } else { try swap(stage, previous) }
                    checkpoint?(4)
                }
                try removeDirectoryIfPresent(stage)
            } else {
                guard try !exists(stage), try !exists(previous) else { throw failure("Estado anterior inesperado") }
            }
            try writeReceipt(Receipt(version: 1, current: after, previous: journal.before)); checkpoint?(5)
            try removeFile(state.appendingPathComponent("disabled"))
        case "rollback":
            guard let before = journal.before, let after = journal.after,
                  try treeHash(destination) == after.treeHash, try treeHash(previous) == before.treeHash else { throw failure("El plugin cambió durante el rollback") }
            try writeReceipt(Receipt(version: 1, current: after, previous: before)); checkpoint?(5)
        case "uninstall":
            guard try !exists(destination) else { throw failure("El plugin reapareció durante la desinstalación") }
            try removeDirectoryIfPresent(stage); try removeDirectoryIfPresent(previous)
            try removeFile(state.appendingPathComponent("receipt.json"))
            try atomicWrite(Data("disabled\n".utf8), to: state.appendingPathComponent("disabled")); checkpoint?(5)
        default: throw failure("Operación del plugin desconocida")
        }
        try removeFile(state.appendingPathComponent("journal.json"))
    }
    private func validateState(_ receipt: Receipt?) throws {
        guard try treeHash(destination) == receipt?.current.treeHash, try treeHash(previous) == receipt?.previous?.treeHash else { throw failure("El plugin o su versión anterior cambiaron fuera de LuaTools") }
    }
    private func validateManifest(_ entries: [ZipArchiveReader.Entry]) throws -> String {
        guard let file = entries.first(where: { $0.path == "plugin.json" }), file.data.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: file.data) as? [String: Any],
              (object["name"] as? String)?.lowercased() == "luatools", let version = object["version"] as? String,
              !version.isEmpty, version.utf8.count <= 128, let platforms = object["platforms"] as? [String], platforms.contains("macos-arm64"),
              let minimum = object["minLuaTools"] as? String else { throw LuaToolsError.invalidRequest }
        let parts = minimum.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw LuaToolsError.invalidRequest }
        let values = parts.compactMap { Int($0) }
        guard values.count == 3, values.allSatisfy({ $0 >= 0 && $0 <= 1_000_000 }), !applicationVersion.lexicographicallyPrecedes(values) else { throw LuaToolsError.invalidRequest }
        for entry in entries {
            guard entry.path == "plugin.json" || entry.path == "README.md" || entry.path.hasPrefix("public/") || entry.path.hasPrefix("backend/") else { throw LuaToolsError.unsafeArchive }
        }
        return version
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if mkdir(state.path, mode_t(0o700)) == 0 { try syncDirectory(parent) }
        else if errno != EEXIST { throw posix("create state", state) }
        var info = stat()
        guard lstat(state.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw failure("Directorio de estado del plugin no seguro") }
        let file = state.appendingPathComponent("lock")
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw posix("open lock", file) }; defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, flock(fd, LOCK_EX) == 0 else { throw failure("Bloqueo del plugin no seguro") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func readReceipt() throws -> Receipt? {
        guard let receipt = try read(Receipt.self, from: state.appendingPathComponent("receipt.json")) else { return nil }
        guard receipt.version == 1 else { throw failure("Registro de instalación del plugin inválido") }; return receipt
    }
    private func writeReceipt(_ receipt: Receipt) throws { try write(receipt, to: state.appendingPathComponent("receipt.json")) }
    private func writeJournal(_ journal: Journal) throws { try write(journal, to: state.appendingPathComponent("journal.json")) }
    private func write<T: Encodable>(_ object: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try atomicWrite(encoder.encode(object), to: url)
    }
    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard try exists(url) else { return nil }
        let data = try readFile(url, limit: 1_048_576)
        guard let result = try? JSONDecoder().decode(type, from: data) else { throw failure("Registro del plugin inválido") }
        return result
    }
    private func treeHash(_ root: URL) throws -> String? {
        guard try exists(root) else { return nil }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw failure("Carpeta del plugin no segura") }
        guard let resolved = realpath(root.path, nil) else { throw posix("resolve plugin directory", root) }
        let canonicalRoot = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        var walkError: Error?
        guard let walker = FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: nil, errorHandler: { _, error in walkError = error; return false }) else { throw failure("No se pudo leer el plugin") }
        var records: [String] = [], total = 0
        for case let url as URL in walker {
            guard url.path.hasPrefix(canonicalRoot.path + "/") else { throw failure("Árbol del plugin inválido: \(url.path), \(canonicalRoot.path)") }
            guard lstat(url.path, &info) == 0 else { throw posix("inspect plugin file", url) }
            let relative = String(url.path.dropFirst(canonicalRoot.path.count + 1))
            guard !relative.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw failure("Ruta del plugin inválida") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: records.append("D\t" + relative)
            case S_IFREG:
                let bytes = try readFile(url, limit: 16 * 1024 * 1024); total += bytes.count
                guard total <= 64 * 1024 * 1024 else { throw LuaToolsError.archiveTooLarge }
                records.append("F\t" + relative + "\t" + hash(bytes))
            default: throw failure("El plugin contiene un enlace o archivo no permitido")
            }
            guard records.count <= 4096 else { throw LuaToolsError.archiveTooLarge }
        }
        if let walkError { throw walkError }
        return hash(Data(records.sorted().joined(separator: "\n").utf8))
    }
    private func readFile(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posix("open", url) }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit else { throw LuaToolsError.unsafeArchive }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw LuaToolsError.archiveTooLarge }; return data
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func exists(_ url: URL) throws -> Bool {
        var info = stat(); if lstat(url.path, &info) == 0 { return true }; if errno == ENOENT { return false }; throw posix("inspect", url)
    }
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".luatools-write-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw posix("open temporary", temporary) }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw posix("write", temporary) }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw posix("fsync", temporary) }
        if fcntl(fd, F_FULLFSYNC) != 0 && errno != EINVAL && errno != ENOTSUP { throw posix("full fsync", temporary) }
        guard rename(temporary.path, url.path) == 0 else { throw posix("rename", url) }
        try syncDirectory(url.deletingLastPathComponent())
    }
    private func renameDirectory(_ source: URL, _ target: URL) throws {
        guard try !exists(target) else { throw failure("El destino del plugin ya existe") }
        guard rename(source.path, target.path) == 0 else { throw posix("rename directory", source) }
        try syncDirectory(parent)
    }
    private func swap(_ first: URL, _ second: URL) throws {
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else { throw posix("swap", first) }
        try syncDirectory(parent)
    }
    private func removeDirectoryIfPresent(_ url: URL) throws {
        guard try exists(url) else { return }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw failure("Carpeta gestionada del plugin no segura") }
        try FileManager.default.removeItem(at: url); try syncDirectory(parent)
    }
    private func removeFile(_ url: URL) throws {
        if unlink(url.path) == 0 { try syncDirectory(url.deletingLastPathComponent()); return }
        if errno != ENOENT { throw posix("remove", url) }
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posix("open directory", url) }; defer { close(fd) }
        if fsync(fd) != 0 && errno != EINVAL && errno != ENOTSUP { throw posix("fsync directory", url) }
    }
    private func failure(_ message: String) -> LuaToolsError { .transactionFailed(message) }
    private func posix(_ operation: String, _ url: URL) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) (\(url.lastPathComponent)): \(String(cString: strerror(code)))"])
    }
}
