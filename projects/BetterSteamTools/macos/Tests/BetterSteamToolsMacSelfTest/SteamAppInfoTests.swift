import Foundation
import CryptoKit
import BetterSteamToolsMacCore

private func word(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
private func fixture(magic: UInt32, oslist: String, arch: String?, duplicate: Bool = false, sparse: Bool = false, launchType: String? = nil, executable: String? = nil, beta: String? = nil, launchOS: String = "macos") -> Data {
    let names = ["appinfo", "common", "name", "oslist", "config", "launch", "0", "osarch", "appid", "type", "executable", "betakey"]
    let indexed = magic == 0x07564429
    func key(_ name: String) -> Data { indexed ? word(UInt64(names.firstIndex(of: name)!), 4) : Data(name.utf8) + Data([0]) }
    func open(_ name: String) -> Data { Data([0]) + key(name) }
    func value(_ name: String, _ value: String) -> Data { Data([1]) + key(name) + Data(value.utf8) + Data([0]) }
    let end = Data([8])
    var common = value("name", "Fixture Game") + value("oslist", oslist)
    if duplicate { common += value("oslist", "windows") }
    var launchConfig = value("oslist", launchOS)
    if let arch { launchConfig += value("osarch", arch) }
    if let beta { launchConfig += value("betakey", beta) }
    var body = Data()
    if sparse {
        for part in [open("appinfo"), Data([2]) + key("appid") + word(42, 4), end, end] { body.append(part) }
    } else {
        let type = launchType.map { value("type", $0) } ?? Data()
        let executablePart = executable.map { value("executable", $0) } ?? Data()
        for part in [open("appinfo"), open("common"), common, end, open("config"), open("launch"), open("0"), type, executablePart, open("config"), launchConfig, end, end, end, end, end, end] { body.append(part) }
    }
    let metaLength = magic >= 0x07564428 ? 60 : 40
    var metadata = Data(repeating: 0, count: metaLength)
    if metaLength == 60 { metadata.replaceSubrange(40..<60, with: Data(Insecure.SHA1.hash(data: body))) }
    let record = word(42, 4) + word(UInt64(metadata.count + body.count), 4) + metadata + body + word(0, 4)
    var header = word(UInt64(magic), 4) + word(1, 4)
    if indexed {
        header += word(UInt64(16 + record.count), 8)
        let table = word(UInt64(names.count), 4) + names.reduce(Data()) { $0 + Data($1.utf8) + Data([0]) }
        return header + record + table
    }
    return header + record
}

func testSteamAppInfo(root: URL) throws {
    let folder = root.appendingPathComponent("appinfo-steam")
    let url = folder.appendingPathComponent("appcache/appinfo.vdf")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let paths = SteamPaths(steamApp: folder.appendingPathComponent("Steam.app"), userData: folder)
    for version: UInt32 in [0x07564427, 0x07564428, 0x07564429] {
        try fixture(magic: version, oslist: "windows,macos", arch: "64").write(to: url)
        let metadata = try SteamAppInfoReader(url: url).read(appID: 42)
        try check(metadata?.name == "Fixture Game" && metadata?.platforms == ["windows", "macos"] && metadata?.supportsMacOS64Bit == true, "appinfo version \(version) parses platform and architecture")
        try check(GameRouter().plan(appID: 42, paths: paths).mode == .native, "confirmed macOS 64-bit metadata selects native")
        try check(SteamAppInfoReader(url: url).read(appID: 999) == nil, "missing app is not invented")
    }
    try fixture(magic: 0x07564429, oslist: "windows,macos", arch: nil).write(to: url)
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .auto, "unknown macOS architecture remains ambiguous")
    try fixture(magic: 0x07564429, oslist: "windows,macos", arch: "64", launchType: "editor").write(to: url)
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .auto, "auxiliary macOS editor does not imply a native default game")
    try fixture(magic: 0x07564429, oslist: "windows,macos", arch: "64", beta: "preview").write(to: url)
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .auto, "beta-only macOS launch does not classify the default game")
    try fixture(magic: 0x07564429, oslist: "", arch: nil, sparse: true).write(to: url)
    let sparse = try SteamAppInfoReader(url: url).read(appID: 42)
    try check(sparse?.name == nil && sparse?.platforms.isEmpty == true && sparse?.supportsMacOS64Bit == nil, "valid sparse appinfo has no invented metadata")
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .auto, "sparse metadata remains ambiguous")
    try fixture(magic: 0x07564429, oslist: "windows,macos", arch: "32").write(to: url)
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .crossover, "32-bit macOS app falls back to declared Windows route")
    try fixture(magic: 0x07564429, oslist: "windows", arch: nil).write(to: url)
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .crossover, "Windows-only metadata selects CrossOver")
    try fixture(magic: 0x07564429, oslist: "windows,macos", arch: "64", duplicate: true).write(to: url)
    try rejects("duplicate platform metadata rejected") { _ = try SteamAppInfoReader(url: url).read(appID: 42) }
    var invalid = fixture(magic: 0x07564429, oslist: "windows", arch: nil)
    invalid[16 + 8 + 40] ^= 1; try invalid.write(to: url)
    try rejects("bad binary checksum rejected") { _ = try SteamAppInfoReader(url: url).read(appID: 42) }
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .auto, "corrupt metadata never chooses a route")
    invalid = fixture(magic: 0x07564429, oslist: "windows", arch: nil); invalid.removeLast(); try invalid.write(to: url)
    try rejects("truncated string table rejected") { _ = try SteamAppInfoReader(url: url).read(appID: 42) }

    let library = SteamLibrary(root: folder)
    let game = library.common.appendingPathComponent("Game")
    let bundle = game.appendingPathComponent("Real Game.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try "\"AppState\" { \"appid\" \"42\" \"installdir\" \"Game\" }".write(to: library.steamapps.appendingPathComponent("appmanifest_42.acf"), atomically: true, encoding: .utf8)
    try machO().write(to: bundle.appendingPathComponent("Game"))
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Game"], format: .xml, options: 0).write(to: bundle.deletingLastPathComponent().appendingPathComponent("Info.plist"))
    try pe().write(to: game.appendingPathComponent("game.exe"))
    try fixture(magic: 0x07564429, oslist: "windows", arch: nil).write(to: url)
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .crossover, "Windows metadata wins over unrelated native helper")
    try fixture(magic: 0x07564429, oslist: "windows,macos", arch: nil, executable: "Real Game.app").write(to: url)
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .native, "declared installed macOS game resolves ambiguous architecture")
    try fixture(magic: 0x07564429, oslist: "windows,macos", arch: nil, executable: "game.exe", launchOS: "windows").write(to: url)
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .crossover, "declared installed Windows game resolves ambiguous architecture")
    try machO().write(to: library.common.appendingPathComponent("outside"))
    try fixture(magic: 0x07564429, oslist: "windows,macos", arch: nil, executable: "../outside").write(to: url)
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .auto, "launch paths outside the installed game cannot classify it")
    try FileManager.default.createSymbolicLink(at: game.appendingPathComponent("linked"), withDestinationURL: library.common.appendingPathComponent("outside"))
    try fixture(magic: 0x07564429, oslist: "windows,macos", arch: nil, executable: "linked").write(to: url)
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .auto, "launch symlinks outside the installed game cannot classify it")
    try FileManager.default.removeItem(at: url)
    try check(GameRouter().plan(appID: 42, paths: paths).mode == .auto, "mixed binaries without metadata remain ambiguous")
}
