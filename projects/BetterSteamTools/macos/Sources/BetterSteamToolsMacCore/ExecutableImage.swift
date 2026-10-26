import Foundation

public enum ExecutableImage {
    public struct Slice: Sendable, Equatable {
        public let cpu: UInt32
        public let fileType: UInt32
        public let is64Bit: Bool
        public var isSupportedMacExecutable: Bool { is64Bit && fileType == 2 && [0x0100000c, 0x01000007].contains(cpu) }
        public var isArm64Dylib: Bool { is64Bit && fileType == 6 && cpu == 0x0100000c }
    }
    public enum ImageError: Error { case malformed }
    private static func uint32(_ bytes: [UInt8], _ offset: Int, little: Bool) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4 else { throw ImageError.malformed }
        let chunk = bytes[offset..<offset + 4]
        return little ? chunk.reversed().reduce(0) { ($0 << 8) | UInt32($1) } : chunk.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private static func uint64(_ bytes: [UInt8], _ offset: Int, little: Bool) throws -> UInt64 {
        guard offset >= 0, offset <= bytes.count - 8 else { throw ImageError.malformed }
        let chunk = bytes[offset..<offset + 8]
        return little ? chunk.reversed().reduce(0) { ($0 << 8) | UInt64($1) } : chunk.reduce(0) { ($0 << 8) | UInt64($1) }
    }
    public static func machOSlices(_ data: Data) throws -> [Slice] {
        let bytes = Array(data)
        func thin(_ offset: Int, limit: Int) throws -> Slice {
            let magic = try uint32(bytes, offset, little: false)
            guard [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe].contains(magic) else { throw ImageError.malformed }
            let little = [0xcefaedfe, 0xcffaedfe].contains(magic)
            let is64 = [0xfeedfacf, 0xcffaedfe].contains(magic)
            let headerSize = is64 ? 32 : 28
            guard limit >= headerSize, offset <= bytes.count - headerSize else { throw ImageError.malformed }
            let loadSize = try uint32(bytes, offset + 20, little: little)
            guard UInt64(loadSize) <= UInt64(limit - headerSize) else { throw ImageError.malformed }
            return Slice(cpu: try uint32(bytes, offset + 4, little: little), fileType: try uint32(bytes, offset + 12, little: little), is64Bit: is64)
        }
        let magic = try uint32(bytes, 0, little: false)
        guard [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) else { return [try thin(0, limit: bytes.count)] }
        let little = [0xbebafeca, 0xbfbafeca].contains(magic)
        let fat64 = [0xcafebabf, 0xbfbafeca].contains(magic)
        let count = Int(try uint32(bytes, 4, little: little))
        let stride = fat64 ? 32 : 20
        guard count > 0, count <= 32, bytes.count >= 8 + stride * count else { throw ImageError.malformed }
        var slices: [Slice] = []
        for index in 0..<count {
            let base = 8 + index * stride
            let offset = fat64 ? try uint64(bytes, base + 8, little: little) : UInt64(try uint32(bytes, base + 8, little: little))
            let size = fat64 ? try uint64(bytes, base + 16, little: little) : UInt64(try uint32(bytes, base + 12, little: little))
            guard offset >= UInt64(8 + stride * count), offset <= UInt64(bytes.count), size <= UInt64(bytes.count) - offset else { throw ImageError.malformed }
            let slice = try thin(Int(offset), limit: Int(size))
            guard slice.cpu == (try uint32(bytes, base, little: little)) else { throw ImageError.malformed }
            slices.append(slice)
        }
        return slices
    }
    public static func machOSlices(at url: URL) -> [Slice] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return (try? machOSlices(data)) ?? []
    }
    public static func isWindowsExecutable(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 64), header.count == 64, header[0] == 0x4d, header[1] == 0x5a,
              let peOffset = try? uint32(Array(header), 60, little: true), peOffset >= 64, peOffset < 16 * 1024 * 1024 else { return false }
        do {
            try handle.seek(toOffset: UInt64(peOffset))
            guard let data = try handle.read(upToCount: 24), data.count == 24, Array(data.prefix(4)) == [0x50, 0x45, 0, 0] else { return false }
            let characteristics = UInt16(data[22]) | UInt16(data[23]) << 8
            return characteristics & 0x0002 != 0 && characteristics & 0x2000 == 0
        } catch { return false }
    }
}
