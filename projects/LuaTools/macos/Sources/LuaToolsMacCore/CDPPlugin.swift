import Foundation

private final class InspectorHTTPPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The same method/path contract used by the Millennium Lua backend. Unsupported actions
/// retain the API's explicit error response; this bridge never manufactures successful RPCs.
public struct PluginRPCDispatcher: Sendable {
    public let router: LocalAPIRouter
    public init(router: LocalAPIRouter = LocalAPIRouter()) { self.router = router }
    public func call(method: String, args: BridgeJSON) async throws -> BridgeJSON {
        if method == "GetCapabilities" {
            return .string(try BridgeJSON.object(["service": .string("luatools"), "apiVersion": .number(1), "transport": .string("cdp")]).encoded())
        }
        let appRoutes = [
            "HasLuaToolsForApp": ("GET", "/has/"), "DeleteLuaToolsForApp": ("POST", "/remove/"),
            "CheckApisForApp": ("POST", "/check-sources/"), "StartAddViaLuaToolsFromUrl": ("POST", "/download/"),
            "GetAddViaLuaToolsStatus": ("GET", "/download-status/"), "CancelAddViaLuaTools": ("POST", "/cancel/"),
            "StartLuaToolsAdd": ("POST", "/add/"), "GetLuaToolsAddStatus": ("GET", "/add-status/"),
            "PickLuaToolsAddSource": ("POST", "/add-source/"), "OpenFix": ("POST", "/open/fix/"), "CheckForFixes": ("GET", "/fixes/")
        ]
        let routes = [
            "OpenSettings": ("POST", "/open/settings"), "RestartSteam": ("POST", "/restart-steam"),
            "OpenExternalUrl": ("POST", "/open-url"), "CheckForUpdatesNow": ("POST", "/check-updates"),
            "ReadLoadedApps": ("GET", "/loaded-apps"), "DismissLoadedApps": ("POST", "/loaded-apps"),
            "GetApiList": ("GET", "/api-list"), "GetIconDataUrl": ("GET", "/icon"), "GetGamesDatabase": ("GET", "/games-database"),
            "GetSettingsConfig": ("GET", "/settings"), "GetThemes": ("GET", "/themes"), "GetInitApisMessage": ("GET", "/init-message"),
            "GetTranslations": ("POST", "/translations"), "Logger.log": ("POST", "/log"), "Logger": ("POST", "/log")
        ]
        let route: (String, String)
        if let appRoute = appRoutes[method] {
            let rawID: String?
            if case .number(let value) = args["appid"], value >= 0, value <= Double(UInt32.max), value.rounded() == value {
                rawID = String(UInt32(value))
            } else { rawID = args["appid"]?.string }
            guard let rawID, !rawID.isEmpty, rawID.allSatisfy({ $0.isASCII && $0.isNumber }), let id = UInt32(rawID),
                  id > 0 || method == "HasLuaToolsForApp" else { throw LuaToolsError.invalidRequest }
            route = (appRoute.0, appRoute.1 + String(id))
        } else if let simple = routes[method] { route = simple }
        else { throw CDPError.protocolError("unknown LuaTools RPC: \(method)") }
        guard case .object = args else { throw LuaToolsError.invalidRequest }
        let body = Data(try args.encoded().utf8)
        guard body.count <= 65_536 else { throw LuaToolsError.invalidRequest }
        let request = LocalHTTPRequest(method: route.0, path: route.1, headers: ["host": "127.0.0.1"], body: body)
        return .string(String(decoding: router.handle(request).body, as: UTF8.self))
    }
}

public actor CDPPluginSession {
    public typealias RPCHandler = @Sendable (String, BridgeJSON) async throws -> BridgeJSON
    private let connection: CDPConnection
    private let handler: RPCHandler
    private var configured = false
    private var contexts: Set<Int> = []
    private var nonce: String?
    private var lastCallID = 0
    private var calls: [UUID: Task<Void, Never>] = [:]
    public init(url: URL, handler: @escaping RPCHandler) throws {
        connection = try CDPConnection(url: url); self.handler = handler
    }
    public static func isStorePage(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        return url.scheme == "https" && url.host == "store.steampowered.com" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }
    public func synchronize(frontend: String) async throws -> String {
        if !configured {
            await connection.start { [weak self] event in await self?.event(event) }
            _ = try await connection.request("Runtime.enable")
            _ = try await connection.request("Runtime.addBinding", params: ["name": .string("__LuaToolsMacRPC")])
            configured = true
        }
        guard let bridgeURL = Bundle.module.url(forResource: "CDPBridge", withExtension: "js") else { throw LuaToolsError.invalidRequest }
        let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)
        let handshake = try await connection.evaluate(bridge)
        guard let transport = handshake["transport"]?.string, ["millennium", "cdp", "excluded"].contains(transport) else { throw CDPError.protocolError("invalid plugin handshake") }
        let nextNonce = handshake["nonce"]?.string
        if nonce != nextNonce { lastCallID = 0 }
        nonce = nextNonce
        if transport == "cdp" {
            let script = "(() => { if (location.origin !== 'https://store.steampowered.com') return false; if (!window.__LuaToolsInjected) { try {\n" + frontend + "\n} catch (error) { delete window.__LuaToolsInjected; delete window.__LuaToolsReady; throw error; } } return window.__LuaToolsInjected === true; })()"
            guard try await connection.evaluate(script).bool == true else { throw CDPError.script("LuaTools frontend did not confirm installation") }
        }
        return transport
    }
    private func event(_ event: BridgeJSON) {
        let params = event["params"]
        switch event["method"]?.string {
        case "Runtime.executionContextCreated":
            if let context = params?["context"], let id = context["id"]?.integer,
               context["origin"]?.string == "https://store.steampowered.com", context["auxData"]?["isDefault"]?.bool == true { contexts.insert(id) }
        case "Runtime.executionContextDestroyed":
            if let id = params?["executionContextId"]?.integer { contexts.remove(id) }
        case "Runtime.executionContextsCleared": contexts.removeAll(); nonce = nil; lastCallID = 0
        case "Runtime.bindingCalled":
            guard params?["name"]?.string == "__LuaToolsMacRPC", let context = params?["executionContextId"]?.integer,
                  contexts.contains(context), let payload = params?["payload"]?.string, payload.utf8.count <= 65_536,
                  let call = try? JSONDecoder().decode(BridgeJSON.self, from: Data(payload.utf8)),
                  let callNonce = call["nonce"]?.string, callNonce == nonce, let id = call["id"]?.integer, id > lastCallID,
                  let method = call["method"]?.string, method.utf8.count <= 128, let args = call["args"] else { return }
            guard calls.count < 32 else { return }
            lastCallID = id
            let key = UUID()
            calls[key] = Task { [weak self, handler] in
                let result: BridgeJSON
                do { result = .object(["id": .number(Double(id)), "nonce": .string(callNonce), "result": try await handler(method, args)]) }
                catch { result = .object(["id": .number(Double(id)), "nonce": .string(callNonce), "error": .string(error.localizedDescription)]) }
                await self?.reply(result, context: context, nonce: callNonce, key: key)
            }
        default: break
        }
    }
    private func reply(_ result: BridgeJSON, context: Int, nonce: String, key: UUID) async {
        defer { calls.removeValue(forKey: key) }
        guard contexts.contains(context), self.nonce == nonce, !Task.isCancelled else { return }
        // contextId prevents a late result reaching the next document after navigation.
        do { _ = try await connection.evaluate("Boolean(window.__LuaToolsMacTransport?.receive(\(try result.encoded())))", contextID: context) }
        catch { /* Navigation/disconnection invalidates the old realm's promises. */ }
    }
    public func close() async {
        for task in calls.values { task.cancel() }; calls.removeAll()
        contexts.removeAll(); nonce = nil
        await connection.close()
    }
}

public struct CDPPluginStatus: Sendable, Equatable {
    public let cdpTabs: Int
    public let millenniumTabs: Int
    public let errors: [String]
}

/// Refreshes the CURRENT document, rather than treating a tab ID as proof of injection.
/// Missing inspector sockets are retried; changed/closed targets are disposed before reuse.
public actor CDPFallbackInjector {
    private struct Tab: Decodable { let id: String; let type: String?; let url: String; let webSocketDebuggerUrl: String? }
    private struct Target { let url: URL; let session: CDPPluginSession }
    private let endpoint: URL
    private let handler: CDPPluginSession.RPCHandler
    private let http: URLSession
    private var targets: [String: Target] = [:]
    private var worker: Task<Void, Never>?
    private var syncing = false
    private var generation: UInt64 = 0
    private var stopped = false
    public init(endpoint: URL = URL(string: "http://127.0.0.1:8080/json")!, handler: CDPPluginSession.RPCHandler? = nil) throws {
        guard CDPConnection.isLoopback(endpoint, schemes: ["http"]), endpoint.port != nil, endpoint.query == nil else { throw CDPError.invalidEndpoint }
        self.endpoint = endpoint
        self.handler = handler ?? { method, args in try await PluginRPCDispatcher().call(method: method, args: args) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        http = URLSession(configuration: configuration, delegate: InspectorHTTPPolicy(), delegateQueue: nil)
    }
    public func synchronize(frontend: String) async throws -> CDPPluginStatus {
        guard !stopped else { throw CDPError.closed }
        guard !syncing else { throw CDPError.protocolError("discovery already in progress") }
        let epoch = generation
        syncing = true; defer { syncing = false }
        let (bytes, response) = try await http.bytes(from: endpoint)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url == endpoint,
              response.expectedContentLength <= 1_048_576 else { throw CDPError.protocolError("invalid inspector discovery response") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw CDPError.protocolError("inspector discovery response too large") }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard generation == epoch, !stopped else { throw CDPError.closed }
        let tabs = try JSONDecoder().decode([Tab].self, from: data)
        guard tabs.count <= 128 else { throw CDPError.protocolError("too many inspector targets") }
        var active: [String: URL] = [:]
        for tab in tabs where (tab.type == nil || tab.type == "page") && CDPPluginSession.isStorePage(tab.url) {
            guard let raw = tab.webSocketDebuggerUrl, let url = URL(string: raw), CDPConnection.isLoopback(url, schemes: ["ws"]),
                  url.port == endpoint.port else { continue }
            active[tab.id] = url
        }
        for id in Array(targets.keys) where targets[id]?.url != active[id] {
            if let old = targets.removeValue(forKey: id) { await old.session.close() }
        }
        var cdp = 0, millennium = 0, errors: [String] = []
        for (id, url) in active.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            guard generation == epoch, !stopped else { throw CDPError.closed }
            do {
                let target: Target
                if let current = targets[id] { target = current }
                else { target = Target(url: url, session: try CDPPluginSession(url: url, handler: handler)); targets[id] = target }
                let transport = try await target.session.synchronize(frontend: frontend)
                try Task.checkCancellation()
                guard generation == epoch, !stopped else { await target.session.close(); throw CDPError.closed }
                switch transport {
                case "cdp": cdp += 1
                case "millennium": millennium += 1
                default: break
                }
            } catch {
                errors.append("\(id): \(error.localizedDescription)")
                if let failed = targets.removeValue(forKey: id) { await failed.session.close() }
            }
        }
        return CDPPluginStatus(cdpTabs: cdp, millenniumTabs: millennium, errors: errors)
    }
    public func start(frontend: String, report: @escaping @Sendable (CDPPluginStatus) async -> Void) {
        guard worker == nil, !stopped else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { await report(try await self.synchronize(frontend: frontend)) }
                catch { await report(CDPPluginStatus(cdpTabs: 0, millenniumTabs: 0, errors: [error.localizedDescription])); await self.discardTargets() }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func discardTargets() async {
        let previous = targets; targets.removeAll()
        for target in previous.values { await target.session.close() }
    }
    public func stop() async {
        stopped = true; generation &+= 1
        worker?.cancel(); worker = nil
        http.invalidateAndCancel()
        await discardTargets()
    }
}
