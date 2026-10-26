import Foundation
import LuaToolsMacCore

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
            let injector = try CDPFallbackInjector(endpoint: root.appendingPathComponent("json")) { method, args in await calls.call(method, args) }
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
            try check(native.millenniumTabs == 1 && native.cdpTabs == 0, "Millennium capability handshake takes precedence")
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
            print("PASS: real WebSocket CDP correlation, notifications, cancellation, timeout, disconnect, origin/context isolation, navigation, Millennium handshake and reconnect")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
