import Foundation

/// Reads Steam's sectioned ContentManifest metadata, including ZIP-wrapped
/// manifests used by Steam. Payload bytes are preserved separately by callers.
struct SteamManifestReader {
    struct Metadata {
        let depotID: UInt32
        let gid: UInt64
        let filenamesEncrypted: Bool
        let sizeOnDisk: UInt64
    }
    private static let payload: UInt32 = 0x71F617D0
    private static let metadata: UInt32 = 0x1F4812BE
    private static let eof: UInt32 = 0x32C415AB

    static func read(_ supplied: Data) throws -> Metadata {
        let data: Data
        if supplied.starts(with: [0x50, 0x4b]) {
            let files = try ZipArchiveReader(data: supplied, maxEntry: 64 * 1024 * 1024, maxTotal: 64 * 1024 * 1024, maxEntries: 64).entries()
            guard files.count == 1 else { throw LuaToolsError.invalidManifest }
            data = files[0].data
        } else { data = supplied }
        let bytes = [UInt8](data)
        func u32(_ at: Int) throws -> UInt32 {
            guard at >= 0, at <= bytes.count - 4 else { throw LuaToolsError.invalidManifest }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        var position = 0, sawPayload = false, sawEOF = false
        var found: Metadata?
        while position <= bytes.count - 4 {
            let magic = try u32(position); position += 4
            if magic == eof { sawEOF = true; break }
            let length = Int(try u32(position)); position += 4
            guard length <= bytes.count - position else { throw LuaToolsError.invalidManifest }
            if magic == payload { sawPayload = true }
            if magic == metadata {
                guard found == nil else { throw LuaToolsError.invalidManifest }
                found = try parseMetadata(Array(bytes[position..<(position + length)]))
            }
            position += length
        }
        guard sawPayload, sawEOF, position == bytes.count, let found else { throw LuaToolsError.invalidManifest }
        return found
    }

    private static func parseMetadata(_ bytes: [UInt8]) throws -> Metadata {
        var position = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard position < bytes.count else { throw LuaToolsError.invalidManifest }
                let byte = bytes[position]; position += 1
                guard index != 9 || byte <= 1 else { throw LuaToolsError.invalidManifest }
                value |= UInt64(byte & 0x7f) << (index * 7)
                if byte & 0x80 == 0 { return value }
            }
            throw LuaToolsError.invalidManifest
        }
        func skip(_ count: UInt64) throws {
            guard count <= UInt64(bytes.count - position) else { throw LuaToolsError.invalidManifest }
            position += Int(count)
        }
        var depot: UInt32?, gid: UInt64?, encrypted = false, size: UInt64 = 0
        while position < bytes.count {
            let tag = try varint(), field = tag >> 3, wire = tag & 7
            guard field > 0 else { throw LuaToolsError.invalidManifest }
            switch wire {
            case 0:
                let value = try varint()
                switch field {
                case 1:
                    guard depot == nil, value > 0, value <= UInt64(UInt32.max) else { throw LuaToolsError.invalidManifest }
                    depot = UInt32(value)
                case 2:
                    guard gid == nil, value > 0 else { throw LuaToolsError.invalidManifest }
                    gid = value
                case 4: encrypted = value != 0
                case 5: size = value
                default: break
                }
            case 1: try skip(8)
            case 2: try skip(varint())
            case 5: try skip(4)
            default: throw LuaToolsError.invalidManifest
            }
        }
        guard let depot, let gid else { throw LuaToolsError.invalidManifest }
        return Metadata(depotID: depot, gid: gid, filenamesEncrypted: encrypted, sizeOnDisk: size)
    }
}
