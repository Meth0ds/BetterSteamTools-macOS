import Foundation
import NativeZip

/// Reads ZIP entries into bounded memory without extracting paths to the file
/// system. Central and local records must agree and every file's CRC is checked.
struct ZipArchiveReader {
    struct Entry { let path: String; let data: Data }
    private let bytes: [UInt8]
    private let maxEntry: Int
    private let maxTotal: Int
    private let maxEntries: Int

    init(data: Data, maxEntry: Int = 64 * 1024 * 1024, maxTotal: Int = 256 * 1024 * 1024, maxEntries: Int = 4096) throws {
        guard maxEntry >= 0, maxTotal >= 0, maxEntries >= 0, data.count <= 256 * 1024 * 1024 else { throw LuaToolsError.archiveTooLarge }
        bytes = Array(data); self.maxEntry = maxEntry; self.maxTotal = maxTotal; self.maxEntries = maxEntries
    }

    private func u16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= bytes.count - 2 else { throw LuaToolsError.unsafeArchive }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4 else { throw LuaToolsError.unsafeArchive }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    private func u64(_ offset: Int) throws -> UInt64 {
        return UInt64(try u32(offset)) | UInt64(try u32(offset + 4)) << 32
    }
    private func span(_ start: Int, _ count: Int) throws -> Range<Int> {
        guard start >= 0, count >= 0, start <= bytes.count, count <= bytes.count - start else { throw LuaToolsError.unsafeArchive }
        return start..<(start + count)
    }
    private func safePath(_ raw: String) throws -> String {
        let value = raw.replacingOccurrences(of: "\\", with: "/")
        guard !value.isEmpty, value.utf8.count <= 1024, !value.hasPrefix("/"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw LuaToolsError.unsafeArchive }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.enumerated().allSatisfy({ index, part in
            !part.isEmpty && part != "." && part != ".." || (index == parts.count - 1 && part.isEmpty)
        }) else { throw LuaToolsError.unsafeArchive }
        return value
    }

    func entries() throws -> [Entry] {
        guard bytes.count >= 22 else { throw LuaToolsError.unsafeArchive }
        let lower = max(0, bytes.count - 22 - 65_535)
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: lower, by: -1) {
            if (try? u32(offset)) == 0x06054b50, let length = try? u16(offset + 20), offset + 22 + Int(length) == bytes.count {
                end = offset; break
            }
        }
        guard let end else { throw LuaToolsError.unsafeArchive }
        guard try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw LuaToolsError.unsafeArchive }
        let shortDiskCount = try u16(end + 8), shortCount = try u16(end + 10)
        let shortDirectorySize = try u32(end + 12), shortDirectoryOffset = try u32(end + 16)
        let locator = end >= 20 && (try? u32(end - 20)) == 0x07064b50
        let hasSentinel = shortDiskCount == UInt16.max || shortCount == UInt16.max || shortDirectorySize == UInt32.max || shortDirectoryOffset == UInt32.max
        let count: Int, directorySize: Int, directoryOffset: Int, directoryEnd: Int
        if locator {
            let location = end - 20
            guard try u32(location + 4) == 0, try u32(location + 16) == 1 else { throw LuaToolsError.unsafeArchive }
            let rawOffset = try u64(location + 8)
            guard rawOffset <= UInt64(location), rawOffset <= UInt64(Int.max) else { throw LuaToolsError.unsafeArchive }
            let record = Int(rawOffset)
            guard record <= location - 12 else { throw LuaToolsError.unsafeArchive }
            guard try u32(record) == 0x06064b50 else { throw LuaToolsError.unsafeArchive }
            let recordSize = try u64(record + 4)
            guard recordSize >= 44, recordSize <= UInt64(location - record - 12), record + 12 + Int(recordSize) == location,
                  try u32(record + 16) == 0, try u32(record + 20) == 0 else { throw LuaToolsError.unsafeArchive }
            let diskCount = try u64(record + 24), fullCount = try u64(record + 32)
            let fullSize = try u64(record + 40), fullOffset = try u64(record + 48)
            guard diskCount == fullCount, fullCount <= UInt64(maxEntries), fullSize <= UInt64(Int.max), fullOffset <= UInt64(Int.max),
                  (shortDiskCount == UInt16.max || UInt64(shortDiskCount) == diskCount),
                  (shortCount == UInt16.max || UInt64(shortCount) == fullCount),
                  (shortDirectorySize == UInt32.max || UInt64(shortDirectorySize) == fullSize),
                  (shortDirectoryOffset == UInt32.max || UInt64(shortDirectoryOffset) == fullOffset) else { throw LuaToolsError.unsafeArchive }
            count = Int(fullCount); directorySize = Int(fullSize); directoryOffset = Int(fullOffset); directoryEnd = record
        } else {
            guard !hasSentinel, shortDiskCount == shortCount else { throw LuaToolsError.unsafeArchive }
            count = Int(shortCount); directorySize = Int(shortDirectorySize); directoryOffset = Int(shortDirectoryOffset); directoryEnd = end
        }
        guard count <= maxEntries, directoryOffset <= directoryEnd, directorySize == directoryEnd - directoryOffset else { throw LuaToolsError.unsafeArchive }
        var cursor = directoryOffset, total = 0
        var occupied: [Range<Int>] = []
        var names = Set<String>(), result: [Entry] = []
        for _ in 0..<count {
            guard try u32(cursor) == 0x02014b50 else { throw LuaToolsError.unsafeArchive }
            _ = try span(cursor, 46)
            let madeBy = try u16(cursor + 4), flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let expectedCRC = try u32(cursor + 16)
            let rawCompressed = try u32(cursor + 20), rawUncompressed = try u32(cursor + 24)
            let nameLength = Int(try u16(cursor + 28)), extraLength = Int(try u16(cursor + 30)), commentLength = Int(try u16(cursor + 32))
            let rawDisk = try u16(cursor + 34), external = try u32(cursor + 38), rawLocal = try u32(cursor + 42)
            let centralEnd = try span(cursor, 46 + nameLength + extraLength + commentLength).upperBound
            guard centralEnd <= directoryEnd else { throw LuaToolsError.unsafeArchive }
            let nameBytes = bytes[try span(cursor + 46, nameLength)]
            let extras = try span(cursor + 46 + nameLength, extraLength)
            var extraCursor = extras.lowerBound, zip64: Range<Int>?
            while extraCursor < extras.upperBound {
                guard extraCursor <= extras.upperBound - 4 else { throw LuaToolsError.unsafeArchive }
                let tag = try u16(extraCursor), size = Int(try u16(extraCursor + 2)); extraCursor += 4
                guard size <= extras.upperBound - extraCursor else { throw LuaToolsError.unsafeArchive }
                if tag == 0x0001 { guard zip64 == nil else { throw LuaToolsError.unsafeArchive }; zip64 = extraCursor..<(extraCursor + size) }
                extraCursor += size
            }
            var zipCursor = zip64?.lowerBound ?? 0
            func nextZip64(_ width: Int) throws -> UInt64 {
                guard let zip64, zipCursor <= zip64.upperBound, width <= zip64.upperBound - zipCursor else { throw LuaToolsError.unsafeArchive }
                let value = width == 8 ? try u64(zipCursor) : UInt64(try u32(zipCursor))
                zipCursor += width; return value
            }
            let fullUncompressed = rawUncompressed == UInt32.max ? try nextZip64(8) : UInt64(rawUncompressed)
            let fullCompressed = rawCompressed == UInt32.max ? try nextZip64(8) : UInt64(rawCompressed)
            let fullLocal = rawLocal == UInt32.max ? try nextZip64(8) : UInt64(rawLocal)
            let fullDisk = rawDisk == UInt16.max ? try nextZip64(4) : UInt64(rawDisk)
            guard flags & 0x2041 == 0, method == 0 || method == 8, fullDisk == 0,
                  fullUncompressed <= UInt64(maxEntry), fullCompressed <= UInt64(bytes.count), fullLocal <= UInt64(directoryOffset) else { throw LuaToolsError.unsafeArchive }
            let compressed = Int(fullCompressed), uncompressed = Int(fullUncompressed), local = Int(fullLocal)
            guard total <= maxTotal - uncompressed else { throw LuaToolsError.archiveTooLarge }
            guard let rawName = String(bytes: nameBytes, encoding: .utf8) else { throw LuaToolsError.unsafeArchive }
            let path = try safePath(rawName)
            guard names.insert(path).inserted else { throw LuaToolsError.archiveConflict }
            let unixMode = (madeBy >> 8) == 3 ? (external >> 16) & 0xf000 : 0
            guard unixMode == 0 || unixMode == 0x8000 || unixMode == 0x4000 else { throw LuaToolsError.unsafeArchive }
            let isDirectory = path.hasSuffix("/")
            guard !(unixMode == 0x4000 && !isDirectory), !(unixMode == 0x8000 && isDirectory), !isDirectory || uncompressed == 0 else { throw LuaToolsError.unsafeArchive }
            guard try u32(local) == 0x04034b50, try u16(local + 6) == flags, try u16(local + 8) == method else { throw LuaToolsError.unsafeArchive }
            let localNameLength = Int(try u16(local + 26)), localExtraLength = Int(try u16(local + 28))
            let localName = bytes[try span(local + 30, localNameLength)]
            guard localName.elementsEqual(nameBytes) else { throw LuaToolsError.unsafeArchive }
            let localExtras = try span(local + 30 + localNameLength, localExtraLength)
            if flags & 0x0008 == 0 {
                let localCRC = try u32(local + 14), localCompressed = try u32(local + 18), localUncompressed = try u32(local + 22)
                var localExtraCursor = localExtras.lowerBound, localZIP64: Range<Int>?
                while localExtraCursor < localExtras.upperBound {
                    guard localExtraCursor <= localExtras.upperBound - 4 else { throw LuaToolsError.unsafeArchive }
                    let tag = try u16(localExtraCursor), size = Int(try u16(localExtraCursor + 2)); localExtraCursor += 4
                    guard size <= localExtras.upperBound - localExtraCursor else { throw LuaToolsError.unsafeArchive }
                    if tag == 0x0001 { guard localZIP64 == nil else { throw LuaToolsError.unsafeArchive }; localZIP64 = localExtraCursor..<(localExtraCursor + size) }
                    localExtraCursor += size
                }
                var localZIPCursor = localZIP64?.lowerBound ?? 0
                func nextLocalZIP64() throws -> UInt64 {
                    guard let localZIP64, localZIPCursor <= localZIP64.upperBound - 8 else { throw LuaToolsError.unsafeArchive }
                    defer { localZIPCursor += 8 }
                    return try u64(localZIPCursor)
                }
                let localFullUncompressed = localUncompressed == UInt32.max ? try nextLocalZIP64() : UInt64(localUncompressed)
                let localFullCompressed = localCompressed == UInt32.max ? try nextLocalZIP64() : UInt64(localCompressed)
                guard localCRC == expectedCRC, localFullCompressed == fullCompressed, localFullUncompressed == fullUncompressed else { throw LuaToolsError.unsafeArchive }
            }
            let dataStart = try span(local, 30 + localNameLength + localExtraLength).upperBound
            let dataRange = try span(dataStart, compressed)
            guard dataRange.upperBound <= directoryOffset else { throw LuaToolsError.unsafeArchive }
            let record = local..<dataRange.upperBound
            guard !occupied.contains(where: { $0.overlaps(record) }) else { throw LuaToolsError.unsafeArchive }
            occupied.append(record)
            if !isDirectory {
                var output = Data(count: uncompressed)
                let ok: Bool = output.withUnsafeMutableBytes { destination in
                    bytes.withUnsafeBufferPointer { source in
                        let input = source.baseAddress?.advanced(by: dataRange.lowerBound)
                        if method == 0 {
                            guard compressed == uncompressed else { return false }
                            if uncompressed > 0 { destination.baseAddress?.copyMemory(from: input!, byteCount: uncompressed) }
                            return true
                        }
                        return luatools_zip_inflate(input, compressed, destination.bindMemory(to: UInt8.self).baseAddress, uncompressed) == 0
                    }
                }
                guard ok, output.withUnsafeBytes({ luatools_zip_crc32($0.bindMemory(to: UInt8.self).baseAddress, output.count) }) == expectedCRC else { throw LuaToolsError.unsafeArchive }
                total += uncompressed
                result.append(Entry(path: path, data: output))
            }
            cursor = centralEnd
        }
        guard cursor == directoryEnd else { throw LuaToolsError.unsafeArchive }
        return result
    }
}
