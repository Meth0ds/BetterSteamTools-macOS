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
func testZipPackage(root: URL) throws {
    let steam = root.appendingPathComponent("zip-steam")
    let paths = SteamMacPaths(steamApp: steam.appendingPathComponent("Steam.app"), userData: steam)
    let source = root.appendingPathComponent("package-source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try "-- package Lua\naddappid(77)\n".write(to: source.appendingPathComponent("77.lua"), atomically: true, encoding: .utf8)
    var manifest = Data([0xD0, 0x17, 0xF6, 0x71])
    manifest.append(Data(repeating: 0x11, count: 8)); manifest.append(Data([0xAB, 0x15, 0xC4, 0x32]))
    try manifest.write(to: source.appendingPathComponent("123_456.manifest"))
    let zip = root.appendingPathComponent("package.zip")
    try Shell.run("/usr/bin/zip", ["-q", "-j", zip.path, source.appendingPathComponent("77.lua").path, source.appendingPathComponent("123_456.manifest").path])
    let installer = LuaInstaller(paths: paths)
    let result = try installer.installZip(appID: 77, zip: zip)
    try check(result.manifests == 1 && installer.hasLua(appID: 77), "ZIP installs Lua and depot manifest")
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
            try testPluginAssets(root: root)
            try testInspectorOwnerPaths(root: root)
            let installer = try testInstallerAndRoutes(root: root)
            try testZipPackage(root: root)
            let server = try LocalAPIServer(installer: installer, port: 0)
            let port = try await server.start()
            defer { server.stop() }
            let response = try await fragmentedTCP(port: port)
            try testLiveListenerOwnership(port: port)
            try check(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200"), "real TCP request succeeds")
            let url = URL(string: "http://127.0.0.1:\(port)/has/42")!
            let (_, rawResponse) = try await URLSession.shared.data(from: url)
            try check((rawResponse as? HTTPURLResponse)?.statusCode == 200, "URLSession can use loopback API")
            print("PASS: atomic Lua install, method-aware routing, malformed HTTP, fragmented TCP and loopback server")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
