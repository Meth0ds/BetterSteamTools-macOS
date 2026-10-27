import Foundation
import CryptoKit
import Darwin

public enum SteamAppInfoError: Error, Equatable { case malformed, unsupportedVersion, tooLarge, changed }
public struct SteamAppMetadata: Sendable, Equatable {
    public let appID: UInt32
    public let name: String?
    public let platforms: Set<String>
    /// True/false only when macOS launch entries explicitly declare an architecture.
    public let supportsMacOS64Bit: Bool?
}

/// Read-only appinfo v27/v28/v29 reader. The file is never mapped: Steam may
/// replace or truncate it while we inspect the requested record.
public struct SteamAppInfoReader: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func read(appID: UInt32) throws -> SteamAppMetadata? {
        guard appID > 0 else { throw SteamAppInfoError.malformed }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw SteamAppInfoError.malformed }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 8 else { throw SteamAppInfoError.malformed }
        let length = UInt64(before.st_size)
        guard length <= 2 * 1024 * 1024 * 1024 else { throw SteamAppInfoError.tooLarge }
        var reader = FileReader(fd: fd, length: length)
        var header = Cursor(data: try reader.read(0, 8))
        let magic = try header.u32(); _ = try header.u32()
        guard [0x07564427, 0x07564428, 0x07564429].contains(magic) else { throw SteamAppInfoError.unsupportedVersion }
        let indexed = magic == 0x07564429, metadataLength = magic >= 0x07564428 ? 60 : 40
        let start: UInt64 = indexed ? 16 : 8
        var strings: [String] = [], recordEnd = length
        if indexed {
            var offsetCursor = Cursor(data: try reader.read(8, 8))
            let tableOffset = try offsetCursor.u64()
            guard tableOffset >= start + 4, tableOffset <= length - 4, length - tableOffset <= 128 * 1024 * 1024 else { throw SteamAppInfoError.malformed }
            recordEnd = tableOffset
            var table = Cursor(data: try reader.read(tableOffset, Int(length - tableOffset)))
            let count = try table.u32()
            guard count <= 1_000_000 else { throw SteamAppInfoError.tooLarge }
            strings.reserveCapacity(Int(count))
            for _ in 0..<count { strings.append(try table.cString(limit: 65_536)) }
        }
        var offset = start, found: Data?, records = 0, terminated = false
        while offset < recordEnd {
            guard recordEnd - offset >= 4 else { throw SteamAppInfoError.malformed }
            var idCursor = Cursor(data: try reader.read(offset, 4))
            let current = try idCursor.u32(); offset += 4
            if current == 0 { terminated = true; break }
            guard offset <= recordEnd - 4 else { throw SteamAppInfoError.malformed }
            var sizeCursor = Cursor(data: try reader.read(offset, 4))
            let size = UInt64(try sizeCursor.u32()); offset += 4
            guard size >= metadataLength, size <= 16 * 1024 * 1024, size <= recordEnd - offset else { throw SteamAppInfoError.malformed }
            records += 1; guard records <= 2_000_000 else { throw SteamAppInfoError.tooLarge }
            if current == appID {
                guard found == nil else { throw SteamAppInfoError.malformed }
                found = try reader.read(offset, Int(size))
            }
            offset += size
        }
        guard terminated else { throw SteamAppInfoError.malformed }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw SteamAppInfoError.changed }
        guard let record = found else { return nil }
        let body = record.subdata(in: metadataLength..<record.count)
        if metadataLength == 60 {
            let expected = record.subdata(in: 40..<60)
            guard Data(Insecure.SHA1.hash(data: body)) == expected else { throw SteamAppInfoError.malformed }
        }
        var cursor = Cursor(data: body), budget = 200_000
        let root = try cursor.table(strings: strings, indexed: indexed, depth: 0, budget: &budget)
        guard cursor.offset == body.count, let app = try root.unique("appinfo")?.object else { throw SteamAppInfoError.malformed }
        let common = try app.unique("common")?.object
        let name = try common?.unique("name")?.text
        let rawPlatforms = try common?.unique("oslist")?.text ?? ""
        let platforms = Set(rawPlatforms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        let config = try app.unique("config")?.object
        let launch = try config?.unique("launch")?.object
        var supported64 = false, supported32 = false, unknownArchitecture = false
        for entry in launch?.properties ?? [] {
            guard let child = entry.object else { continue }
            // An auxiliary editor or tool is not evidence that the default game runs on macOS.
            let type = try child.unique("type")?.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard type.isEmpty || type == "default" else { continue }
            guard let launchConfig = try child.unique("config")?.object,
                  let oslist = try launchConfig.unique("oslist")?.text else { continue }
            let operatingSystems = oslist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard operatingSystems.contains("macos") else { continue }
            let arch = try launchConfig.unique("osarch")?.text?.lowercased()
            if arch == "64" || arch == "x86_64" || arch == "arm64" { supported64 = true }
            else if arch == "32" || arch == "x86" { supported32 = true }
            else { unknownArchitecture = true }
        }
        let mac64: Bool? = supported64 ? true : (supported32 && !unknownArchitecture ? false : nil)
        return SteamAppMetadata(appID: appID, name: name, platforms: platforms, supportsMacOS64Bit: mac64)
    }
}

private struct FileReader {
    let fd: Int32; let length: UInt64
    private var cacheStart: UInt64 = 0; private var cache = Data()
    init(fd: Int32, length: UInt64) { self.fd = fd; self.length = length }
    mutating func read(_ position: UInt64, _ count: Int) throws -> Data {
        guard count >= 0, position <= length, UInt64(count) <= length - position else { throw SteamAppInfoError.malformed }
        if count <= 65_536 {
            if position < cacheStart || position - cacheStart > UInt64(cache.count) || UInt64(count) > UInt64(cache.count) - (position - cacheStart) {
                cacheStart = position; cache = try exact(position, min(65_536, Int(length - position)))
            }
            let begin = Int(position - cacheStart)
            return cache.subdata(in: begin..<(begin + count))
        }
        return try exact(position, count)
    }
    private func exact(_ position: UInt64, _ count: Int) throws -> Data {
        var data = Data(count: count), done = 0
        try data.withUnsafeMutableBytes { bytes in
            while done < count {
                let got = pread(fd, bytes.baseAddress!.advanced(by: done), count - done, off_t(position) + off_t(done))
                if got < 0 && errno == EINTR { continue }
                guard got > 0 else { throw SteamAppInfoError.changed }; done += got
            }
        }
        return data
    }
}

private struct BinaryProperty { let name: String; let text: String?; let object: BinaryObject? }
private struct BinaryObject {
    let properties: [BinaryProperty]
    func unique(_ name: String) throws -> BinaryProperty? {
        let matches = properties.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count <= 1 else { throw SteamAppInfoError.malformed }
        return matches.first
    }
}
private struct Cursor {
    let data: Data; var offset = 0
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else { throw SteamAppInfoError.malformed }
        defer { offset += count }; return data.subdata(in: offset..<(offset + count))
    }
    mutating func u8() throws -> UInt8 { guard offset < data.count else { throw SteamAppInfoError.malformed }; defer { offset += 1 }; return data[offset] }
    mutating func u32() throws -> UInt32 { let b = [UInt8](try bytes(4)); return (0..<4).reduce(0) { $0 | UInt32(b[$1]) << (8 * $1) } }
    mutating func u64() throws -> UInt64 { let b = [UInt8](try bytes(8)); return (0..<8).reduce(0) { $0 | UInt64(b[$1]) << (8 * $1) } }
    mutating func cString(limit: Int) throws -> String {
        let start = offset
        while offset < data.count && offset - start <= limit && data[offset] != 0 { offset += 1 }
        guard offset < data.count, offset - start <= limit else { throw SteamAppInfoError.malformed }
        let value = String(decoding: data[start..<offset], as: UTF8.self); offset += 1; return value
    }
    mutating func table(strings: [String], indexed: Bool, depth: Int, budget: inout Int) throws -> BinaryObject {
        guard depth < 64 else { throw SteamAppInfoError.tooLarge }
        var properties: [BinaryProperty] = []
        while true {
            let type = try u8(); if type == 8 || type == 11 { return BinaryObject(properties: properties) }
            budget -= 1; guard budget >= 0 else { throw SteamAppInfoError.tooLarge }
            let name: String
            if indexed { let index = Int(try u32()); guard index < strings.count else { throw SteamAppInfoError.malformed }; name = strings[index] }
            else { name = try cString(limit: 65_536) }
            switch type {
            case 0: properties.append(BinaryProperty(name: name, text: nil, object: try table(strings: strings, indexed: indexed, depth: depth + 1, budget: &budget)))
            case 1: properties.append(BinaryProperty(name: name, text: try cString(limit: 1_048_576), object: nil))
            case 2, 3, 4, 6: _ = try bytes(4); properties.append(BinaryProperty(name: name, text: nil, object: nil))
            case 7, 10: _ = try bytes(8); properties.append(BinaryProperty(name: name, text: nil, object: nil))
            default: throw SteamAppInfoError.malformed
            }
        }
    }
}
