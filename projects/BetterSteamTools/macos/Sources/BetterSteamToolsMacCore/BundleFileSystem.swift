import Foundation
import CryptoKit
import Darwin

/// macOS copies retain ACLs, resource forks, extended attributes and executable modes.
/// Staging and RENAME_SWAP never expose a half-written Steam bundle at its launch path.
enum BundleFileSystem {
    static func status(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw posix("lstat", url)
    }
    static func requireRegular(_ url: URL) throws {
        guard let info = try status(url), info.st_mode & S_IFMT == S_IFREG else { throw BundleError.invalidReceipt }
    }
    static func refuseSymlinks(_ url: URL, inside root: URL) throws {
        guard url.standardizedFileURL.path == root.standardizedFileURL.path || url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw BundleError.invalidReceipt }
        var cursor = url
        while true {
            if let info = try status(cursor), info.st_mode & S_IFMT == S_IFLNK { throw BundleError.invalidReceipt }
            if cursor.standardizedFileURL == root.standardizedFileURL { break }
            cursor.deleteLastPathComponent()
        }
    }
    static func clone(_ source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else { throw posix("copyfile", destination) }
    }
    static func swap(_ first: URL, _ second: URL) throws {
        guard first.deletingLastPathComponent() == second.deletingLastPathComponent() else { throw BundleError.invalidReceipt }
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else { throw posix("rename swap", first) }
        try syncDirectory(first.deletingLastPathComponent())
    }
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".bst-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let existing = try status(url) {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw BundleError.invalidReceipt }
            guard copyfile(url.path, temporary.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0 else { throw posix("copy metadata", url) }
        }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw posix("open temporary file", temporary) }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posix("write", temporary) }
                offset += count
            }
        }
        try syncFile(descriptor, url: temporary)
        guard rename(temporary.path, url.path) == 0 else { throw posix("rename file", url) }
        try syncDirectory(url.deletingLastPathComponent())
    }
    static func remove(_ url: URL) throws {
        guard try status(url) != nil else { return }
        try FileManager.default.removeItem(at: url)
        try syncDirectory(url.deletingLastPathComponent())
    }
    static func syncFile(_ descriptor: Int32, url: URL) throws {
        guard fsync(descriptor) == 0 else { throw posix("fsync", url) }
        if fcntl(descriptor, F_FULLFSYNC) != 0 && errno != EINVAL && errno != ENOTSUP { throw posix("full fsync", url) }
    }
    static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posix("open directory", url) }
        defer { close(descriptor) }
        if fsync(descriptor) != 0 && errno != EINVAL && errno != ENOTSUP { throw posix("sync directory", url) }
    }
    static func syncTree(_ root: URL) throws {
        for url in try entries(root).reversed() {
            guard let info = try status(url) else { throw BundleError.recoveryConflict }
            if info.st_mode & S_IFMT == S_IFREG {
                let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard descriptor >= 0 else { throw posix("open staged file", url) }
                do { try syncFile(descriptor, url: url); close(descriptor) }
                catch { close(descriptor); throw error }
            } else if info.st_mode & S_IFMT == S_IFDIR { try syncDirectory(url) }
        }
    }
    static func entries(_ root: URL) throws -> [URL] {
        var failure: Error?
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in failure = error; return false }) else { throw BundleError.steamMissing }
        var urls = [root]
        for case let url as URL in walk { urls.append(url) }
        if let failure { throw failure }
        return urls.sorted { $0.path < $1.path }
    }
    struct TreeEntry: Codable {
        let path: String
        let mode: UInt16
        let uid: UInt32
        let gid: UInt32
        let content: String
        let attributes: [String: String]
        let acl: String
    }
    /// Content and security metadata identify the state. Access times and inode
    /// numbers intentionally do not: reading or cloning legitimately changes them.
    static func fingerprint(_ rootURL: URL) throws -> String {
        // FileManager may return canonical /private/var children when the
        // caller used /var. Relative paths must use the same canonical root.
        guard let resolved = realpath(rootURL.path, nil) else { throw posix("resolve snapshot root", rootURL) }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        guard let rootStatus = try status(root), rootStatus.st_mode & S_IFMT == S_IFDIR else { throw BundleError.steamMissing }
        var records: [TreeEntry] = []
        for url in try entries(root) {
            guard let info = try status(url) else { throw BundleError.recoveryConflict }
            let content: String
            switch info.st_mode & S_IFMT {
            case S_IFREG: content = try SteamBuildManifest.hashFile(url)
            case S_IFDIR: content = "directory"
            case S_IFLNK: content = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            default: throw BundleError.invalidReceipt
            }
            guard url == root || url.path.hasPrefix(root.path + "/") else { throw BundleError.recoveryConflict }
            let relative = url == root ? "." : String(url.path.dropFirst(root.path.count + 1))
            records.append(TreeEntry(path: relative, mode: info.st_mode, uid: info.st_uid, gid: info.st_gid,
                                     content: content, attributes: try xattrs(url), acl: try aclText(url)))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return hash(try encoder.encode(records))
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func xattrs(_ url: URL) throws -> [String: String] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        if size < 0 && errno == ENOTSUP { return [:] }
        guard size >= 0, size <= 1_048_576 else { throw posix("list extended attributes", url) }
        if size == 0 { return [:] }
        var names = [CChar](repeating: 0, count: size)
        let copied = listxattr(url.path, &names, names.count, XATTR_NOFOLLOW)
        guard copied == size else { throw BundleError.recoveryConflict }
        var values: [String: String] = [:]
        for name in names.split(separator: 0) {
            let key = String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let length = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0, length <= 16_777_216 else { throw posix("get extended attribute size", url) }
            var data = Data(count: length)
            let actual = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
            guard actual == length else { throw BundleError.recoveryConflict }
            values[key] = hash(data)
        }
        return values
    }
    private static func aclText(_ url: URL) throws -> String {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP { return "" }
            throw posix("read ACL", url)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var size = 0
        guard let text = acl_to_text(acl, &size) else { throw posix("encode ACL", url) }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }
    static func posix(_ operation: String, _ url: URL) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) (\(url.lastPathComponent)): \(String(cString: strerror(code)))"])
    }
}
