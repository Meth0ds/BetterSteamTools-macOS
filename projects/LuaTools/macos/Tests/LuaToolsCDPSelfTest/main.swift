import Foundation
@_spi(Testing) import LuaToolsMacCore

struct Failure: Error, CustomStringConvertible { let description: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(description: message) }
}
func rejects(_ message: String, _ operation: @Sendable () async throws -> Void) async throws {
    do { try await operation() } catch { return }
    throw Failure(description: message)
}
actor Recorder {
    var calls: [(String, BridgeJSON)] = []
    var notifications = 0
    func event(_ event: BridgeJSON) { if event["method"]?.string == "Fixture.notification" { notifications += 1 } }
    func call(_ method: String, _ args: BridgeJSON) -> BridgeJSON { calls.append((method, args)); return .string("{\"success\":true,\"exists\":true}") }
    func count() -> Int { calls.count }
}
actor ServiceReports {
    private var current: CDPPluginStatus?
    func record(_ status: CDPPluginStatus) { current = status }
    func latest() -> CDPPluginStatus? { current }
}

@main struct CDPSelfTest {
    static func json(_ root: URL, _ path: String) async throws -> BridgeJSON {
        let (data, response) = try await URLSession.shared.data(from: root.appendingPathComponent(path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(description: "fixture HTTP failed") }
        return try JSONDecoder().decode(BridgeJSON.self, from: data)
    }
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2, let root = URL(string: CommandLine.arguments[1]), let port = root.port else { throw Failure(description: "Run with Tests/CDP/fake_inspector.py") }
            let socketURL = URL(string: "ws://127.0.0.1:\(port)/ws/direct")!
            let recorder = Recorder()
            let connection = try CDPConnection(url: socketURL)
            await connection.start { event in await recorder.event(event) }
            async let first = connection.request("Fixture.echo", params: ["value": .string("slow"), "delay": .number(0.08)])
            async let second = connection.request("Fixture.echo", params: ["value": .string("fast"), "delay": .number(0.01)])
            let replies = try await (first, second)
            try check(replies.0["echo"]?.string == "slow" && replies.1["echo"]?.string == "fast", "out-of-order fragmented replies correlate by ID")
            try await rejects("remote CDP error must throw") { _ = try await connection.request("Fixture.remoteError") }
            try await rejects("script exceptions must throw") { _ = try await connection.evaluate("fixture.throw") }
            try await rejects("unanswered commands must time out") { _ = try await connection.request("Fixture.wait", timeout: .milliseconds(40)) }
            let cancellation = Task { try await connection.request("Fixture.wait") }
            try await Task.sleep(for: .milliseconds(10)); cancellation.cancel()
            try await rejects("cancelled command must fail") { _ = try await cancellation.value }
            let recovered = try await connection.request("Fixture.echo", params: ["value": .string("still-live")])
            try check(recovered["echo"]?.string == "still-live", "timeout/cancellation does not break other requests")
            let waiting = Task { try await connection.request("Fixture.wait") }
            try await rejects("disconnect fails request") { _ = try await connection.request("Fixture.disconnect") }
            try await rejects("disconnect drains pending continuations") { _ = try await waiting.value }
            await connection.close()
            let notificationCount = await recorder.notifications
            try check(notificationCount >= 3, "notifications delivered independently of replies")

            for raw in ["https://store.steampowered.com.evil.test/", "https://store.steampowered.com@evil.test/", "http://store.steampowered.com/", "https://store.steampowered.com:444/"] {
                try check(!CDPPluginSession.isStorePage(raw), "reject foreign/untrusted origin")
            }
            try check(CDPPluginSession.isStorePage("https://store.steampowered.com/app/42/"), "accept real store page")
            for raw in ["ws://example.com:8080/ws/1", "ws://127.0.0.1.evil.test:8080/ws/1", "ws://user@127.0.0.1:8080/ws/1"] {
                do { _ = try CDPConnection(url: URL(string: raw)!); throw Failure(description: "remote socket accepted") }
                catch is CDPError { }
            }
            let calls = Recorder()
            let injector = try LuaLoaderCDPInjector(endpoint: root.appendingPathComponent("json"), inspectorAuthorizer: { _ in }) { method, args in await calls.call(method, args) }
            let frontend = "window.__fixtureFrontend = true; window.__LuaToolsInjected = true;"
            let initial = try await injector.synchronize(frontend: frontend)
            try check(initial.cdpTabs == 1 && initial.errors.isEmpty, "discover only validated store targets and sockets")
            try await Task.sleep(for: .milliseconds(140))
            let count = await calls.count()
            try check(count == 1, "only default store context with current nonce can invoke RPC")
            let stats = try await json(root, "stats")
            guard case .array(let responses) = stats["replies"] else { throw Failure(description: "missing reply statistics") }
            try check(responses.count == 1 && responses[0]["id"]?.integer == 1 && responses[0]["context"]?.integer == 7, "RPC response returns its ID and execution context")
            _ = try await json(root, "control/navigate")
            let navigated = try await injector.synchronize(frontend: frontend)
            try check(navigated.cdpTabs == 1, "same tab is checked again after navigation")
            try await Task.sleep(for: .milliseconds(140))
            let navigatedCount = await calls.count()
            try check(navigatedCount == 2, "new context/nonce can invoke RPC after navigation")
            _ = try await json(root, "control/native")
            let native = try await injector.synchronize(frontend: frontend)
            try check(native.cdpTabs == 1 && native.errors.isEmpty, "LuaLoader remains the primary route when a legacy backend appears")
            _ = try await json(root, "control/legacy-handshake")
            let legacy = try await injector.synchronize(frontend: frontend)
            try check(legacy.cdpTabs == 0 && legacy.errors.count == 1, "unexpected legacy-loader handshake is rejected")
            _ = try await json(root, "control/broken")
            let failed = try await injector.synchronize(frontend: frontend)
            try check(failed.cdpTabs == 0 && failed.errors.count == 1, "frontend acknowledgement is required")
            _ = try await json(root, "control/cdp")
            let reconnected = try await injector.synchronize(frontend: frontend)
            try check(reconnected.cdpTabs == 1 && reconnected.errors.isEmpty, "failed targets reconnect cleanly")
            await injector.stop()
            let dispatcher = PluginRPCDispatcher()
            try await rejects("unknown RPC must fail") { _ = try await dispatcher.call(method: "Unknown", args: .object([:])) }
            try await rejects("AppID traversal must fail") { _ = try await dispatcher.call(method: "DeleteLuaToolsForApp", args: .object(["appid": .string("../../file")])) }
            try await rejects("unimplemented backend operation rejects the plugin promise") { _ = try await dispatcher.call(method: "RestartSteam", args: .object([:])) }
            _ = try await json(root, "control/navigate")
            let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("luatools-service-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: fixtureRoot) }
            let plugin = fixtureRoot.appendingPathComponent("plugin/public")
            try FileManager.default.createDirectory(at: plugin.appendingPathComponent("themes"), withIntermediateDirectories: true)
            try "window.__fixtureFrontend = true; window.__LuaToolsInjected = true;".write(to: plugin.appendingPathComponent("luatools.js"), atomically: true, encoding: .utf8)
            try "body {}".write(to: plugin.appendingPathComponent("steamdb-webkit.css"), atomically: true, encoding: .utf8)
            try #"[{"value":"original"}]"#.write(to: plugin.appendingPathComponent("themes/themes.json"), atomically: true, encoding: .utf8)
            try ":root {}".write(to: plugin.appendingPathComponent("themes/original.css"), atomically: true, encoding: .utf8)
            let paths = SteamMacPaths(steamApp: fixtureRoot.appendingPathComponent("Steam.app"), userData: fixtureRoot)
            let service = LuaToolsBackgroundService(installer: LuaInstaller(paths: paths), pluginDirectory: plugin.deletingLastPathComponent(), port: 0,
                                                    inspectorEndpoint: root.appendingPathComponent("json"), inspectorAuthorizer: { _ in })
            let reports = ServiceReports()
            let localPort = try await service.start { await reports.record($0) }
            let (health, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(localPort)/health")!)
            let healthJSON = try JSONDecoder().decode(BridgeJSON.self, from: health)
            try check((response as? HTTPURLResponse)?.statusCode == 200 && healthJSON["service"]?.string == "luatools", "service owns the real local API")
            try await Task.sleep(for: .milliseconds(400))
            let before = try await json(root, "stats")["frontends"]?.integer ?? 0
            try check(before > 0, "service starts the LuaLoader CDP injector")
            try "window.__fixtureFrontend = true; window.__LuaToolsInjected = true; // updated".write(to: plugin.appendingPathComponent("luatools.js"), atomically: true, encoding: .utf8)
            await service.refreshPlugin()
            try await Task.sleep(for: .milliseconds(1200))
            let pending = await reports.latest()
            let still = try await json(root, "stats")["frontends"]?.integer ?? 0
            try check(pending?.pendingReloadTabs == 1 && still == before, "updated frontend waits for navigation without duplicate injection")
            _ = try await json(root, "control/navigate")
            try await Task.sleep(for: .milliseconds(1200))
            let after = try await json(root, "stats")["frontends"]?.integer ?? 0
            let reloaded = await reports.latest()
            try check(after > before && reloaded?.pendingReloadTabs == 0, "navigation applies the updated plugin assets")
            await service.stop()
            print("PASS: real WebSocket CDP correlation, notifications, cancellation, timeout, disconnect, origin/context isolation, navigation, LuaLoader selection and reconnect")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
