import Foundation
import CryptoKit
import Darwin

/// Durable, per-Steam-directory transaction for Lua and depotcache writes.
/// Prepared journals are rolled back on the next operation; committed journals
/// are only cleaned up. A foreign edit is reported rather than overwritten.
public struct PackageTransaction {
    public struct Write {
        let relativePath: String
        let data: Data?
        public init(relativePath: String, data: Data) { self.relativePath = relativePath; self.data = data }
        private init(relativePath: String) { self.relativePath = relativePath; self.data = nil }
        public static func remove(_ relativePath: String) -> Write { Write(relativePath: relativePath) }
    }
    private struct Entry: Codable {
        let relativePath: String
        let beforeHash: String?
        let afterHash: String?
        let backup: String?
    }
    private struct Journal: Codable { let version: Int; var phase: String; let entries: [Entry] }
    private let root: URL
    private let state: URL
    private let checkpoint: ((Int) -> Void)?

    public init(paths: SteamMacPaths) throws { try self.init(paths: paths, checkpoint: nil) }

    @_spi(Testing) public init(paths: SteamMacPaths, checkpoint: ((Int) -> Void)?) throws {
        guard let resolved = realpath(paths.userData.path, nil) else { throw LuaToolsError.transactionFailed("No se pudo localizar la carpeta de Steam") }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        state = root.appendingPathComponent("config/.luatools-transactions", isDirectory: true)
        self.checkpoint = checkpoint
    }

    public func recover() throws { try withLock { try recoverLocked() } }
    public func apply(_ writes: [Write]) throws {
        guard !writes.isEmpty, Set(writes.map(\.relativePath)).count == writes.count else { throw LuaToolsError.archiveConflict }
        try withLock {
            try recoverLocked()
            let directory = state.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try syncDirectory(state)
            var entries: [Entry] = []
            do {
                for (index, write) in writes.enumerated() {
                    let destination = try target(write.relativePath)
                    let previous = try readFile(destination)
                    let backupName = previous == nil ? nil : "backup-\(index)"
                    if let backupName {
                        let backup = directory.appendingPathComponent(backupName)
                        guard copyfile(destination.path, backup.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0 else { throw posix("backup", destination) }
                        try syncFile(backup)
                        guard let copied = try readFile(backup), hash(copied) == previous.map(hash) else { throw LuaToolsError.transactionFailed("El archivo cambió durante la copia de seguridad: \(write.relativePath)") }
                    }
                    entries.append(Entry(relativePath: write.relativePath, beforeHash: previous.map(hash), afterHash: write.data.map(hash), backup: backupName))
                }
                var journal = Journal(version: 1, phase: "prepared", entries: entries)
                try writeJournal(journal, directory: directory)
                checkpoint?(0)
                for (index, write) in writes.enumerated() {
                    let destination = try target(write.relativePath)
                    guard try readFile(destination).map(hash) == entries[index].beforeHash else { throw LuaToolsError.transactionFailed("El archivo cambió durante la instalación: \(write.relativePath)") }
                    if entries[index].beforeHash == entries[index].afterHash {
                        checkpoint?(index + 1)
                        continue
                    }
                    if let data = write.data {
                        try atomicWrite(data, to: destination, temporaryName: temporaryName(directory, index, restoring: false), beforeRename: {
                            guard try readFile(destination).map(hash) == entries[index].beforeHash else { throw LuaToolsError.transactionFailed("El archivo cambió durante la instalación: \(write.relativePath)") }
                            checkpoint?(-index - 1)
                        })
                    } else {
                        checkpoint?(-index - 1)
                        guard try readFile(destination).map(hash) == entries[index].beforeHash else { throw LuaToolsError.transactionFailed("El archivo cambió durante la eliminación: \(write.relativePath)") }
                        guard unlink(destination.path) == 0 else { throw posix("remove", destination) }
                        try syncDirectory(destination.deletingLastPathComponent())
                    }
                    checkpoint?(index + 1)
                }
                journal.phase = "committed"
                try writeJournal(journal, directory: directory)
                checkpoint?(writes.count + 1)
                try removeDirectory(directory)
            } catch {
                do { try recoverDirectory(directory) }
                catch { throw LuaToolsError.transactionFailed("No se pudo recuperar la transacción: \(error.localizedDescription)") }
                throw error
            }
        }
    }

    private func withLock(_ action: () throws -> Void) throws {
        let config = root.appendingPathComponent("config", isDirectory: true)
        try requireDirectory(config)
        if mkdir(state.path, mode_t(0o700)) != 0 && errno != EEXIST { throw posix("create recovery directory", state) }
        try syncDirectory(config)
        var info = stat()
        guard lstat(state.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw LuaToolsError.transactionFailed("Directorio de recuperación no seguro") }
        let file = state.appendingPathComponent(".lock")
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw posix("open lock", file) }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw LuaToolsError.transactionFailed("Bloqueo de instalación no seguro") }
        guard flock(fd, LOCK_EX) == 0 else { throw posix("lock", file) }
        defer { flock(fd, LOCK_UN) }
        try action()
    }

    private func recoverLocked() throws {
        let contents = try FileManager.default.contentsOfDirectory(at: state, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != ".lock" }
        for directory in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { throw LuaToolsError.transactionFailed("Entrada desconocida en el directorio de recuperación") }
            try recoverDirectory(directory)
        }
    }
    private func recoverDirectory(_ directory: URL) throws {
        try requireDirectory(directory)
        let journalFile = directory.appendingPathComponent("journal.json")
        guard let data = try readFile(journalFile) else { try removeDirectory(directory); return }
        guard data.count <= 1_048_576, let journal = try? JSONDecoder().decode(Journal.self, from: data), journal.version == 1,
              ["prepared", "committed"].contains(journal.phase), !journal.entries.isEmpty, journal.entries.count <= 4097,
              Set(journal.entries.map(\.relativePath)).count == journal.entries.count else { throw LuaToolsError.transactionFailed("Registro de recuperación inválido") }
        // Validate every path and backup before changing any target.
        for (index, entry) in journal.entries.enumerated() {
            _ = try target(entry.relativePath)
            guard entry.afterHash?.count == 64 || entry.afterHash == nil, entry.beforeHash?.count == 64 || entry.beforeHash == nil else { throw LuaToolsError.transactionFailed("Hash de recuperación inválido") }
            if let backup = entry.backup {
                guard backup == "backup-\(index)", entry.beforeHash != nil else { throw LuaToolsError.transactionFailed("Copia de seguridad no válida") }
            } else if entry.beforeHash != nil { throw LuaToolsError.transactionFailed("Falta una copia de seguridad") }
        }
        if journal.phase == "committed" {
            for (index, entry) in journal.entries.enumerated() {
                let destination = try target(entry.relativePath)
                try cleanTemporary(destination, named: temporaryName(directory, index, restoring: false))
                try cleanTemporary(destination, named: temporaryName(directory, index, restoring: true))
            }
            try removeDirectory(directory); return
        }
        for entry in journal.entries {
            if let backup = entry.backup {
                guard let data = try readFile(directory.appendingPathComponent(backup)), hash(data) == entry.beforeHash else { throw LuaToolsError.transactionFailed("Copia de seguridad no válida") }
            }
        }
        for (index, entry) in journal.entries.enumerated().reversed() {
            let destination = try target(entry.relativePath)
            try cleanTemporary(destination, named: temporaryName(directory, index, restoring: false))
            try cleanTemporary(destination, named: temporaryName(directory, index, restoring: true))
            let current = try readFile(destination).map(hash)
            if current == entry.beforeHash { continue }
            guard current == entry.afterHash else { throw LuaToolsError.transactionFailed("El archivo cambió después de la interrupción: \(entry.relativePath)") }
            if let backup = entry.backup {
                try restoreCopy(directory.appendingPathComponent(backup), to: destination, temporaryName: temporaryName(directory, index, restoring: true))
            } else {
                guard unlink(destination.path) == 0 else { throw posix("remove", destination) }
                try syncDirectory(destination.deletingLastPathComponent())
            }
        }
        try removeDirectory(directory)
    }

    private func target(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        let filename: Substring
        if parts.count == 3 && parts[0] == "config" && parts[1] == "stplug-in" { filename = parts[2] }
        else if parts.count == 2 && parts[0] == "depotcache" { filename = parts[1] }
        else { throw LuaToolsError.transactionFailed("Ruta de recuperación inválida") }
        let pattern = parts.count == 3 ? #"^[1-9][0-9]{0,9}\.lua(?:\.disabled)?$"# : #"^[1-9][0-9]{0,9}_[1-9][0-9]{0,19}\.manifest$"#
        guard filename.range(of: pattern, options: .regularExpression) != nil else { throw LuaToolsError.transactionFailed("Nombre de recuperación inválido") }
        if parts.count == 3 {
            guard let id = UInt32(filename.split(separator: ".").first ?? ""), id > 0 else { throw LuaToolsError.transactionFailed("AppID de recuperación inválido") }
        } else {
            let values = filename.dropLast(".manifest".count).split(separator: "_")
            guard values.count == 2, let depot = UInt32(values[0]), depot > 0, let gid = UInt64(values[1]), gid > 0 else { throw LuaToolsError.transactionFailed("Depot de recuperación inválido") }
        }
        let destination = root.appendingPathComponent(relative)
        try requireDirectory(destination.deletingLastPathComponent())
        return destination
    }
    private func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw LuaToolsError.transactionFailed("Directorio no accesible: \(url.lastPathComponent)") }
    }
    private func readFile(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw posix("open", url) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 64 * 1024 * 1024 else { throw LuaToolsError.transactionFailed("Archivo de recuperación no válido") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 * 1024 else { throw LuaToolsError.transactionFailed("Archivo de recuperación demasiado grande") }
        return data
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func writeJournal(_ journal: Journal, directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= 1_048_576 else { throw LuaToolsError.transactionFailed("El registro de recuperación es demasiado grande") }
        try atomicWrite(data, to: directory.appendingPathComponent("journal.json"))
        try syncDirectory(directory)
    }
    private func temporaryName(_ directory: URL, _ index: Int, restoring: Bool) -> String {
        ".luatools-\(restoring ? "restore" : "write")-\(directory.lastPathComponent)-\(index)"
    }
    private func cleanTemporary(_ destination: URL, named name: String) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(name)
        var info = stat()
        if lstat(temporary.path, &info) != 0 {
            if errno == ENOENT { return }
            throw posix("inspect temporary", temporary)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw LuaToolsError.transactionFailed("Archivo temporal de recuperación no seguro") }
        guard unlink(temporary.path) == 0 else { throw posix("remove temporary", temporary) }
        try syncDirectory(temporary.deletingLastPathComponent())
    }
    private func atomicWrite(_ data: Data, to url: URL, temporaryName: String? = nil, beforeRename: (() throws -> Void)? = nil) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(temporaryName ?? ".luatools-write-\(UUID().uuidString)")
        var ownsTemporary = false
        defer { if ownsTemporary { unlink(temporary.path) } }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw LuaToolsError.transactionFailed("Destino no es un archivo regular") }
            guard copyfile(url.path, temporary.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0 else { throw posix("copy metadata", url) }
            ownsTemporary = true
        } else if errno != ENOENT { throw posix("inspect", url) }
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | (ownsTemporary ? O_TRUNC : O_EXCL)
        let fd = open(temporary.path, flags, mode_t(0o600))
        guard fd >= 0 else { throw posix("open temporary", temporary) }
        ownsTemporary = true
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posix("write", temporary) }; offset += count
            }
        }
        try syncDescriptor(fd, url: temporary)
        try beforeRename?()
        guard rename(temporary.path, url.path) == 0 else { throw posix("rename", url) }
        try syncDirectory(url.deletingLastPathComponent())
    }
    private func restoreCopy(_ backup: URL, to destination: URL, temporaryName: String) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(temporaryName)
        var ownsTemporary = false
        defer { if ownsTemporary { unlink(temporary.path) } }
        guard copyfile(backup.path, temporary.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0 else { throw posix("restore", destination) }
        ownsTemporary = true
        try syncFile(temporary)
        guard rename(temporary.path, destination.path) == 0 else { throw posix("restore rename", destination) }
        try syncDirectory(destination.deletingLastPathComponent())
    }
    private func syncFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posix("open sync", url) }; defer { close(fd) }
        try syncDescriptor(fd, url: url)
    }
    private func syncDescriptor(_ fd: Int32, url: URL) throws {
        guard fsync(fd) == 0 else { throw posix("fsync", url) }
        if fcntl(fd, F_FULLFSYNC) != 0 && errno != EINVAL && errno != ENOTSUP { throw posix("full fsync", url) }
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posix("open directory", url) }; defer { close(fd) }
        if fsync(fd) != 0 && errno != EINVAL && errno != ENOTSUP { throw posix("fsync directory", url) }
    }
    private func removeDirectory(_ url: URL) throws { try FileManager.default.removeItem(at: url); try syncDirectory(state) }
    private func posix(_ operation: String, _ url: URL) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) (\(url.lastPathComponent)): \(String(cString: strerror(code)))"])
    }
}
