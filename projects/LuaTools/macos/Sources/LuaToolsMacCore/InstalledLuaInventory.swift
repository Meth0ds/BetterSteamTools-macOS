import Foundation
import Darwin

public struct InstalledLua: Identifiable, Sendable, Equatable {
    public let appID: UInt32
    public let url: URL
    public let name: String?
    public let modified: Date
    public var id: UInt32 { appID }
}

/// Mirrors the Windows installed-game scan: numeric AppID .lua files only.
public struct InstalledLuaInventory: Sendable {
    private let paths: SteamMacPaths
    public init(paths: SteamMacPaths = .detected) { self.paths = paths }
    public func list() throws -> [InstalledLua] {
        var info = stat()
        if lstat(paths.stPlugin.path, &info) != 0 {
            if errno == ENOENT { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw LuaToolsError.transactionFailed("La carpeta de Lua no es un directorio") }
        let files = try FileManager.default.contentsOfDirectory(at: paths.stPlugin, includingPropertiesForKeys: nil)
        var result: [InstalledLua] = []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".lua"), let number = name.split(separator: ".").first,
                  !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let id = UInt32(number), id > 0, name == "\(id).lua" else { continue }
            let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 8192) ?? Data()
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            var title: String?
            if lines.count > 1, lines[0].localizedCaseInsensitiveContains("Created by"), lines[1].hasPrefix("--") {
                let candidate = lines[1].drop(while: { $0 == "-" || $0 == " " }).trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { title = candidate }
            }
            result.append(InstalledLua(appID: id, url: file, name: title, modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))))
        }
        return result.sorted { $0.modified == $1.modified ? $0.appID < $1.appID : $0.modified > $1.modified }
    }
}
