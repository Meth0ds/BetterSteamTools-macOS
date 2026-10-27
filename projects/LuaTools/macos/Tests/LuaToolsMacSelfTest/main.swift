import Foundation
import Network
import LuaToolsMacCore

struct TestFailure: Error, CustomStringConvertible { let description: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(description: message) }
}
func request(_ method: String, _ path: String, extra: String = "", body: Data = Data()) throws -> LocalHTTPRequest {
    var parser = LocalHTTPRequestParser()
    let wire = Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\n\(extra)\r\n".utf8) + body
    guard let result = try parser.append(wire) else { throw TestFailure(description: "request should parse") }
    return result
}
func testParser() throws {
    let body = Data("{\"source\":\"value\"}".utf8)
    let wire = Data("POST /add/42 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
    var parser = LocalHTTPRequestParser()
    var result: LocalHTTPRequest?
    for byte in wire { result = try parser.append(Data([byte])) }
    try check(result?.body == body && result?.path == "/add/42", "fragmented request retains its body")
    for bad in [
        "GET / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\na",
        "GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\nGET /other HTTP/1.1\r\n\r\n"
    ] {
        var parser = LocalHTTPRequestParser()
        var rejected = false
        do { _ = try parser.append(Data(bad.utf8)) } catch { rejected = true }
        try check(rejected, "reject ambiguous HTTP framing")
    }
}
func testInstallerAndRoutes(root: URL) throws -> LuaInstaller {
    let paths = SteamMacPaths(steamApp: root.appendingPathComponent("Steam.app"), userData: root)
    let source = root.appendingPathComponent("42.lua")
    let installer = LuaInstaller(paths: paths)
    let lua = "-- local config\naddappid(42)\n"
    try lua.write(to: source, atomically: true, encoding: .utf8)
    let result = try installer.installLua(appID: 42, source: source)
    try check(result.appID == 42 && installer.hasLua(appID: 42), "Lua installed in stplug-in")
    _ = try installer.installLua(appID: 42, source: result.luaURL)
    try check(String(contentsOf: result.luaURL, encoding: .utf8) == lua, "installing from destination does not delete source")
    let router = LocalAPIRouter(installer: installer)
    let exists = router.handle(try request("GET", "/has/42"))
    let object = try JSONSerialization.jsonObject(with: exists.body) as! [String: Any]
    try check(exists.status == 200 && object["exists"] as? Bool == true, "has reports real disk state")
    try check(router.handle(request("GET", "/remove/42")).status == 405, "GET never removes a file")
    try check(installer.hasLua(appID: 42), "GET removal leaves file intact")
    try check(router.handle(request("POST", "/remove/42", extra: "Origin: https://example.com\r\n")).status == 403, "foreign page cannot mutate installation")
    try check(router.handle(request("GET", "/has/not-a-number")).status == 400, "invalid AppID is a client error")
    try check(router.handle(request("GET", "/has/4294967296")).status == 400, "AppID overflow rejected")
    try check(router.handle(request("POST", "/restart-steam")).status == 501, "unimplemented operation does not return success")
    for path in ["/settings", "/themes", "/init-message", "/translations", "/games-database", "/fixes/42", "/log"] {
        try check(router.handle(request("GET", path)).status == 501, "unfinished RPC is explicit: \(path)")
    }
    try check(router.handle(request("GET", "/missing")).status == 404, "unknown route returns 404")
    try check(router.handle(request("POST", "/remove/42")).status == 200, "POST removes configuration")
    try check(!installer.hasLua(appID: 42), "removal visible on disk")
    try installer.removeLua(appID: 42)
    return installer
}
func testInstalledLuaInventory(root: URL) throws {
    let steam = root.appendingPathComponent("inventory-steam")
    let paths = SteamMacPaths(steamApp: steam.appendingPathComponent("Steam.app"), userData: steam)
    let inventory = InstalledLuaInventory(paths: paths)
    try check(inventory.list().isEmpty, "missing Lua folder is empty")
    try FileManager.default.createDirectory(at: paths.stPlugin, withIntermediateDirectories: true)
    try Data("-- Created by LuaTools\n-- Fixture Game\naddappid(42)".utf8).write(to: paths.stPlugin.appendingPathComponent("42.lua"))
    try Data("-- other".utf8).write(to: paths.stPlugin.appendingPathComponent("43.lua"))
    try Data("-- not a game".utf8).write(to: paths.stPlugin.appendingPathComponent("Steamtools.lua"))
    try Data("-- disabled".utf8).write(to: paths.stPlugin.appendingPathComponent("44.lua.disabled"))
    try FileManager.default.createSymbolicLink(at: paths.stPlugin.appendingPathComponent("45.lua"), withDestinationURL: paths.stPlugin.appendingPathComponent("42.lua"))
    let installed = try inventory.list()
    try check(Set(installed.map(\.appID)) == Set([42, 43]), "inventory lists only regular numeric Lua files")
    try check(installed.first(where: { $0.appID == 42 })?.name == "Fixture Game", "Windows-style Lua title parsed")
}
func fixtureManifest(depot: UInt32, gid: UInt64, size: UInt64 = 4096) -> Data {
    func number(_ value: UInt64) -> [UInt8] {
        var remaining = value, result: [UInt8] = []
        repeat { var byte = UInt8(remaining & 0x7f); remaining >>= 7; if remaining != 0 { byte |= 0x80 }; result.append(byte) } while remaining != 0
        return result
    }
    func word(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    let metadata: [UInt8] = [0x08] + number(UInt64(depot)) + [0x10] + number(gid) + [0x20, 0x01, 0x28] + number(size)
    return Data(word(0x71f617d0) + word(0) + word(0x1f4812be) + word(UInt32(metadata.count)) + metadata + word(0x32c415ab))
}
func testStandaloneManifests(root: URL) throws {
    let steam = root.appendingPathComponent("standalone-manifests")
    let paths = SteamMacPaths(steamApp: steam.appendingPathComponent("Steam.app"), userData: steam)
    let installer = LuaInstaller(paths: paths)
    let sources = root.appendingPathComponent("manifest-sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let first = sources.appendingPathComponent("123_456.manifest"), second = sources.appendingPathComponent("124_457.manifest")
    let firstBytes = fixtureManifest(depot: 123, gid: 456), secondBytes = fixtureManifest(depot: 124, gid: 457)
    try firstBytes.write(to: first); try secondBytes.write(to: second)
    try check(installer.installManifests(sources: [first, second]).count == 2, "standalone manifests installed")
    let target = paths.depotCache.appendingPathComponent(first.lastPathComponent)
    try check(Data(contentsOf: target) == firstBytes, "manifest bytes preserved")
    _ = try installer.installManifests(sources: [target])
    try check(Data(contentsOf: target) == firstBytes, "installing from depotcache preserves content")
    try fixtureManifest(depot: 999, gid: 457).write(to: second)
    var rejected = false
    do { _ = try installer.installManifests(sources: [first, second]) } catch { rejected = true }
    try check(rejected && Data(contentsOf: target) == firstBytes && Data(contentsOf: paths.depotCache.appendingPathComponent(second.lastPathComponent)) == secondBytes, "invalid manifest leaves the entire prior set intact")
    let link = sources.appendingPathComponent("125_458.manifest")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
    rejected = false; do { _ = try installer.installManifests(sources: [link]) } catch { rejected = true }
    try check(rejected, "symlinked manifest rejected")
}
func zip64Fixture(_ ordinary: Data) throws -> Data {
    guard let range = ordinary.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards) else { throw TestFailure(description: "ZIP end record fixture") }
    let offset = range.lowerBound
    func read(_ start: Int, _ width: Int) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { $0 | UInt64(ordinary[start + $1]) << ($1 * 8) }
    }
    func word(_ value: UInt64, _ width: Int) -> Data { Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    let count = read(offset + 10, 2), size = read(offset + 12, 4), directoryOffset = read(offset + 16, 4)
    var record = Data()
    let recordFields: [(UInt64, Int)] = [(0x06064b50, 4), (44, 8), (45, 2), (45, 2), (0, 4), (0, 4), (count, 8), (count, 8), (size, 8), (directoryOffset, 8)]
    for (value, width) in recordFields { record.append(word(value, width)) }
    var locator = Data()
    let locatorFields: [(UInt64, Int)] = [(0x07064b50, 4), (0, 4), (UInt64(offset), 8), (1, 4)]
    for (value, width) in locatorFields { locator.append(word(value, width)) }
    var end = ordinary.subdata(in: offset..<ordinary.count)
    end.replaceSubrange(8..<12, with: Data(repeating: 0xff, count: 4))
    end.replaceSubrange(12..<20, with: Data(repeating: 0xff, count: 8))
    return ordinary.subdata(in: 0..<offset) + record + locator + end
}
func zip64EntryFixture(_ ordinary: Data) throws -> Data {
    guard let endRange = ordinary.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards) else { throw TestFailure(description: "ZIP entry end fixture") }
    let end = endRange.lowerBound
    func read(_ start: Int, _ width: Int) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { $0 | UInt64(ordinary[start + $1]) << ($1 * 8) }
    }
    func word(_ value: UInt64, _ width: Int) -> Data { Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    let central = Int(read(end + 16, 4)), centralSize = read(end + 12, 4)
    let nameLength = Int(read(central + 28, 2)), extraLength = Int(read(central + 30, 2))
    let insert = central + 46 + nameLength + extraLength
    let compressed = read(central + 20, 4), uncompressed = read(central + 24, 4), localOffset = read(central + 42, 4)
    let extra = word(1, 2) + word(24, 2) + word(uncompressed, 8) + word(compressed, 8) + word(localOffset, 8)
    var result = ordinary
    result.replaceSubrange((central + 20)..<(central + 28), with: Data(repeating: 0xff, count: 8))
    result.replaceSubrange((central + 42)..<(central + 46), with: Data(repeating: 0xff, count: 4))
    result.replaceSubrange((central + 30)..<(central + 32), with: word(UInt64(extraLength + extra.count), 2))
    result.insert(contentsOf: extra, at: insert)
    result.replaceSubrange((end + extra.count + 12)..<(end + extra.count + 16), with: word(centralSize + UInt64(extra.count), 4))
    return result
}
func testZipPackage(root: URL) throws {
    let steam = root.appendingPathComponent("zip-steam")
    let paths = SteamMacPaths(steamApp: steam.appendingPathComponent("Steam.app"), userData: steam)
    let source = root.appendingPathComponent("package-source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try "-- package Lua\naddappid(77)\n".write(to: source.appendingPathComponent("77.lua"), atomically: true, encoding: .utf8)
    let manifest = fixtureManifest(depot: 123, gid: 456)
    try manifest.write(to: source.appendingPathComponent("123_456.manifest"))
    let parsed = try DepotManifest(fileName: "123_456.manifest", bytes: manifest)
    try check(parsed.depotID == 123 && parsed.manifestGID == 456 && parsed.sizeOnDisk == 4096 && parsed.filenamesEncrypted, "manifest metadata matches its filename")
    var rejectedMismatch = false
    do { _ = try DepotManifest(fileName: "124_456.manifest", bytes: manifest) } catch { rejectedMismatch = true }
    try check(rejectedMismatch, "manifest identity must agree with its filename")
    let wrapped = root.appendingPathComponent("wrapped.zip")
    try Shell.run("/usr/bin/zip", ["-q", "-j", wrapped.path, source.appendingPathComponent("123_456.manifest").path])
    let wrappedBytes = try Data(contentsOf: wrapped)
    try check(DepotManifest(fileName: "123_456.manifest", bytes: wrappedBytes).manifestGID == 456, "ZIP-wrapped Steam manifests are supported")
    let zip = root.appendingPathComponent("package.zip")
    try Shell.run("/usr/bin/zip", ["-q", "-j", zip.path, source.appendingPathComponent("77.lua").path, source.appendingPathComponent("123_456.manifest").path])
    let installer = LuaInstaller(paths: paths)
    let result = try installer.installZip(appID: 77, zip: zip)
    try check(result.manifests == 1 && installer.hasLua(appID: 77), "ZIP installs Lua and depot manifest")
    let downloaded = try installer.installDownloaded(appID: 77, data: Data(contentsOf: zip))
    try check(downloaded.manifests == 1, "downloaded ZIP detected by signature and installed")
    let rawLua = Data("-- bare download\naddappid(79)\n".utf8)
    let bare = try installer.installDownloaded(appID: 79, data: rawLua)
    try check(Data(contentsOf: bare.luaURL) == rawLua, "bare downloaded Lua installed without a ZIP wrapper")
    try check(Data(contentsOf: paths.depotCache.appendingPathComponent("123_456.manifest")) == manifest, "manifest bytes remain unchanged")
    try "old".write(to: result.luaURL, atomically: true, encoding: .utf8)
    let invalid = root.appendingPathComponent("invalid-source", isDirectory: true)
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    try "77.lua".write(to: invalid.appendingPathComponent("77.lua"), atomically: true, encoding: .utf8)
    try Data(repeating: 0, count: 16).write(to: invalid.appendingPathComponent("123_456.manifest"))
    let invalidZip = root.appendingPathComponent("invalid.zip")
    try Shell.run("/usr/bin/zip", ["-q", "-j", invalidZip.path, invalid.appendingPathComponent("77.lua").path, invalid.appendingPathComponent("123_456.manifest").path])
    var rejected = false
    do { _ = try installer.installZip(appID: 77, zip: invalidZip) } catch { rejected = true }
    try check(rejected, "invalid depot manifest must rollback")
    try check(String(contentsOf: result.luaURL, encoding: .utf8) == "old", "failed package leaves previous Lua untouched")
    var traversal = try Data(contentsOf: zip)
    let oldName = Data("77.lua".utf8), badName = Data("../bad".utf8)
    var search = traversal.startIndex, replacements = 0
    while search < traversal.endIndex, let match = traversal.range(of: oldName, in: search..<traversal.endIndex) {
        traversal.replaceSubrange(match, with: badName); search = match.upperBound; replacements += 1
    }
    try check(replacements == 2, "fixture changes both ZIP file-name records")
    let traversalZip = root.appendingPathComponent("traversal.zip"); try traversal.write(to: traversalZip)
    rejected = false
    do { _ = try installer.installZip(appID: 77, zip: traversalZip) } catch { rejected = true }
    try check(rejected && String(contentsOf: result.luaURL, encoding: .utf8) == "old", "ZIP traversal is rejected before any write")
    let link = source.appendingPathComponent("link.lua")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.appendingPathComponent("77.lua"))
    let linkZip = root.appendingPathComponent("link.zip")
    try Shell.run("/usr/bin/zip", ["-q", "-j", "-y", linkZip.path, link.path])
    rejected = false
    do { _ = try installer.installZip(appID: 77, zip: linkZip) } catch { rejected = true }
    try check(rejected && String(contentsOf: result.luaURL, encoding: .utf8) == "old", "ZIP symlinks are rejected before any write")
    let largeLua = source.appendingPathComponent("78.lua")
    let largeContent = "-- " + String(repeating: "compressed fixture ", count: 10000) + "\naddappid(78)\n"
    try largeContent.write(to: largeLua, atomically: true, encoding: .utf8)
    let compressedZip = root.appendingPathComponent("compressed.zip")
    try Shell.run("/usr/bin/zip", ["-q", "-j", compressedZip.path, largeLua.path])
    let compressedResult = try installer.installZip(appID: 78, zip: compressedZip)
    try check(String(contentsOf: compressedResult.luaURL, encoding: .utf8) == largeContent, "deflated ZIP payload is installed byte-for-byte")
    let zip64 = root.appendingPathComponent("zip64.zip")
    try zip64Fixture(Data(contentsOf: compressedZip)).write(to: zip64)
    let zip64Result = try installer.installZip(appID: 79, zip: zip64)
    try check(String(contentsOf: zip64Result.luaURL, encoding: .utf8) == largeContent, "ZIP64 end records preserve valid package contents")
    let zip64Entry = root.appendingPathComponent("zip64-entry.zip")
    try zip64Fixture(zip64EntryFixture(Data(contentsOf: compressedZip))).write(to: zip64Entry)
    let zip64EntryResult = try installer.installZip(appID: 80, zip: zip64Entry)
    try check(String(contentsOf: zip64EntryResult.luaURL, encoding: .utf8) == largeContent, "ZIP64 entry sizes and offsets are honored")
    var corrupt = try Data(contentsOf: compressedZip)
    guard let central = corrupt.range(of: Data([0x50, 0x4b, 0x01, 0x02])) else { throw TestFailure(description: "ZIP central directory fixture") }
    corrupt[central.lowerBound + 16] ^= 0x80
    let corruptZip = root.appendingPathComponent("corrupt.zip"); try corrupt.write(to: corruptZip)
    rejected = false
    do { _ = try installer.installZip(appID: 78, zip: corruptZip) } catch { rejected = true }
    try check(rejected && String(contentsOf: compressedResult.luaURL, encoding: .utf8) == largeContent, "CRC mismatch rejects the archive before replacing Lua")
}
func fragmentedTCP(port: UInt16) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        let queue = DispatchQueue(label: "selftest.client")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        final class State: @unchecked Sendable { var done = false; var output = Data() }
        let state = State()
        @Sendable func finish(_ result: Result<Data, Error>) {
            guard !state.done else { return }; state.done = true; connection.cancel(); continuation.resume(with: result)
        }
        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data { state.output.append(data) }
                if let error { finish(.failure(error)); return }
                if complete { finish(.success(state.output)) } else { receive() }
            }
        }
        connection.stateUpdateHandler = { status in
            if case .failed(let error) = status { finish(.failure(error)) }
            if case .ready = status {
                connection.send(content: Data("GET /he".utf8), completion: .contentProcessed { error in
                    if let error { finish(.failure(error)); return }
                    queue.asyncAfter(deadline: .now() + 0.02) {
                        connection.send(content: Data("alth HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8), completion: .contentProcessed { error in
                            if let error { finish(.failure(error)) } else { receive() }
                        })
                    }
                })
            }
        }
        queue.asyncAfter(deadline: .now() + 4) { finish(.failure(TestFailure(description: "TCP response timed out"))) }
        connection.start(queue: queue)
    }
}

@main struct SelfTest {
    static func main() async {
        if CommandLine.arguments.count == 3, ["--auth-lock-hold", "--auth-lock-crash"].contains(CommandLine.arguments[1]) {
            do { try await authLockChild(root: URL(fileURLWithPath: CommandLine.arguments[2]), crash: CommandLine.arguments[1] == "--auth-lock-crash") }
            catch { fputs("auth lock child failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--removal-crash", let point = Int(CommandLine.arguments[3]) {
            do { try removalChild(root: URL(fileURLWithPath: CommandLine.arguments[2]), stop: point) }
            catch { fputs("removal child failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--plugin-crash", let point = Int(CommandLine.arguments[5]) {
            do { try pluginCrashChild(destination: URL(fileURLWithPath: CommandLine.arguments[2]), archive: URL(fileURLWithPath: CommandLine.arguments[3]), operation: CommandLine.arguments[4], stop: point) }
            catch { fputs("plugin child failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--transaction-hold" {
            do { try transactionHoldingChild(root: URL(fileURLWithPath: CommandLine.arguments[2])) }
            catch { fputs("transaction child failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--transaction-crash", let point = Int(CommandLine.arguments[3]) {
            do { try transactionChild(root: URL(fileURLWithPath: CommandLine.arguments[2]), stop: point) }
            catch { fputs("transaction child failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--inspect-port", let port = UInt16(CommandLine.arguments[2]) {
            do {
                let owners = try NativeSteamInspector.listeners(port: port)
                for owner in owners { print("pid=\(owner.pid) loopback=\(owner.loopbackOnly) executable=\(owner.executable)") }
                do { try NativeSteamInspector.authorize(URL(string: "http://127.0.0.1:\(port)/json")!); print("AUTHORIZED: native Steam inspector") }
                catch { print("REFUSED: \(error.localizedDescription)") }
                return
            } catch { fputs("Inspector diagnostic failed: \(error)\n", stderr); exit(1) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("luatools-selftest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try testParser()
            try await testAuthentication()
            try await testLuaToolsAPIClient()
            try await testPluginAddFlow(root: root)
            try await testAccountFileLock(root: root)
            try testInstalledLuaInventory(root: root)
            try testBSTHelper(root: root)
            try testPluginAssets(root: root)
            try testPluginInstaller(root: root)
            try testInspectorOwnerPaths(root: root)
            try testServiceOwnerPaths(root: root)
            try testSteamInspectorLauncher(root: root)
            try testLaunchAgent(root: root)
            let installer = try testInstallerAndRoutes(root: root)
            try testZipPackage(root: root)
            try testStandaloneManifests(root: root)
            try testPackageTransactionCrashRecovery(root: root)
            try testRemovalRecovery(root: root)
            let server = try LocalAPIServer(installer: installer, port: 0)
            let port = try await server.start()
            defer { server.stop() }
            let response = try await fragmentedTCP(port: port)
            try testLiveListenerOwnership(port: port)
            try check(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200"), "real TCP request succeeds")
            let url = URL(string: "http://127.0.0.1:\(port)/has/42")!
            let (_, rawResponse) = try await URLSession.shared.data(from: url)
            try check((rawResponse as? HTTPURLResponse)?.statusCode == 200, "URLSession can use loopback API")
            print("PASS: Lua/manifest ZIP installation, crash recovery, process locking, HTTP routing and loopback server")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
