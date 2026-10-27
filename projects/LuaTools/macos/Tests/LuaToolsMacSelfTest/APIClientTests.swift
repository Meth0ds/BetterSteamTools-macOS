import Foundation
@_spi(Testing) import LuaToolsMacCore

private actor APIFixture {
    var requests: [URLRequest] = []
    var status = 200
    func send(_ request: URLRequest, maximum: Int) -> (Data, Int) {
        requests.append(request)
        if request.url?.path == "/check_apis" { return (Data(#"{"Sushi":"available","Ryuu":"unavailable"}"#.utf8), status) }
        return (Data("-- fixture Lua".utf8), status)
    }
    func all() -> [URLRequest] { requests }
    func reject() { status = 403 }
}

private actor AddFixture {
    var slowDownload = false
    var count = 0
    func setSlow(_ value: Bool) { slowDownload = value }
    func send(_ request: URLRequest, maximum: Int) async throws -> (Data, Int) {
        if request.url?.path == "/check_apis" { return (Data(#"{"Sushi":"available","Sadie (Morrenus)":"available"}"#.utf8), 200) }
        count += 1
        if slowDownload { try await Task.sleep(for: .seconds(5)) }
        return (Data("-- fixture download\naddappid(42)\n".utf8), 200)
    }
}

func testPluginAddFlow(root: URL) async throws {
    let fixture = AddFixture()
    let api = LuaToolsAPIClient(token: { "fixture-token" }, transport: { try await fixture.send($0, maximum: $1) })
    let steam = root.appendingPathComponent("plugin-add-steam")
    let paths = SteamMacPaths(steamApp: steam.appendingPathComponent("Steam.app"), userData: steam)
    let installer = LuaInstaller(paths: paths), coordinator = PluginAddCoordinator(api: api, installer: LuaInstaller(paths: paths))
    let router = LocalAPIRouter(installer: installer, addCoordinator: coordinator)
    let start = try request("POST", "/add/42", body: Data(#"{"name":"Example"}"#.utf8))
    let started = await router.handleAsync(start); try check(started.status == 200, "store add starts a real source lookup")
    let deadline = Date().addingTimeInterval(3)
    while await coordinator.state(appID: 42)?.sourcesLoaded != true && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let stateResponse = await router.handleAsync(try request("GET", "/add-status/42"))
    let state = try JSONSerialization.jsonObject(with: stateResponse.body) as? [String: Any]
    let sources = state?["sources"] as? [[String: Any]] ?? []
    try check(sources.count == 2 && sources.first(where: { $0["name"] as? String == "Sadie (Morrenus)" })?["locked"] as? Bool == true, "keyed source remains locked until its backend is implemented")
    let invalid = await router.handleAsync(try request("POST", "/add-source/42", body: Data(#"{"source":"Unknown"}"#.utf8)))
    try check(invalid.status == 400, "unknown source refused")
    let selected = await router.handleAsync(try request("POST", "/add-source/42", body: Data(#"{"source":"Sushi"}"#.utf8)))
    try check(selected.status == 200, "available source accepted")
    while await coordinator.state(appID: 42)?.busy == true && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let result = await router.handleAsync(try request("GET", "/add-status/42"))
    let installed = try JSONSerialization.jsonObject(with: result.body) as? [String: Any]
    try check(installed?["installed"] as? Bool == true && installer.hasLua(appID: 42), "source download installs Lua and reports actual disk state")
    await fixture.setSlow(true)
    _ = await router.handleAsync(try request("POST", "/add/43"))
    while await coordinator.state(appID: 43)?.sourcesLoaded != true && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    _ = await router.handleAsync(try request("POST", "/add-source/43", body: Data(#"{"source":"Sushi"}"#.utf8)))
    let cancelled = await router.handleAsync(try request("POST", "/cancel/43"))
    try check(cancelled.status == 200 && !installer.hasLua(appID: 43), "cancelling an in-flight download prevents installation")
    let forbidden = await router.handleAsync(try request("POST", "/add/44", extra: "Origin: https://example.com\r\n"))
    try check(forbidden.status == 403, "foreign origins cannot start add jobs")
    await fixture.setSlow(false)
    let dispatcher = PluginRPCDispatcher(router: router)
    _ = try await dispatcher.call(method: "StartLuaToolsAdd", args: .object(["appid": .number(45), "name": .string("RPC Fixture")]))
    while await coordinator.state(appID: 45)?.sourcesLoaded != true && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    _ = try await dispatcher.call(method: "PickLuaToolsAddSource", args: .object(["appid": .number(45), "source": .string("Sushi")]))
    while await coordinator.state(appID: 45)?.busy == true && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try check(installer.hasLua(appID: 45), "plugin RPC dispatch drives the same real add flow")
    let server = try LocalAPIServer(router: router, port: 0)
    let port = try await server.start(); defer { server.stop() }
    var post = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/add/46")!); post.httpMethod = "POST"; post.httpBody = Data("{}".utf8)
    let (_, response) = try await URLSession.shared.data(for: post)
    try check((response as? HTTPURLResponse)?.statusCode == 200, "loopback HTTP listener dispatches asynchronous add route")
}

func testLuaToolsAPIClient() async throws {
    let fixture = APIFixture()
    let client = LuaToolsAPIClient(token: { "fixture-token" }, transport: { request, limit in await fixture.send(request, maximum: limit) })
    let sources = try await client.checkSources(appID: 42)
    try check(sources.count == 2 && sources.first(where: { $0.name == "Sushi" })?.available == true, "source availability follows backend response")
    let data = try await client.downloadManifest(appID: 42, source: "Sushi & test", gameName: "Game + title")
    try check(data == Data("-- fixture Lua".utf8), "download bytes returned unchanged")
    let requests = await fixture.all()
    let source = requests[0], download = requests[1]
    try check(source.url?.scheme == "http" && source.url?.path == "/check_apis" && source.value(forHTTPHeaderField: "Authorization") == nil, "source check does not transmit credentials")
    let query = URLComponents(url: download.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    try check(download.url?.host == "lua.tools" && download.url?.scheme == "https" && download.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "download token only sent to configured HTTPS host")
    try check(query.first(where: { $0.name == "source" })?.value == "Sushi & test" && query.first(where: { $0.name == "game_name" })?.value == "Game + title", "query values are encoded without changing their content")
    await fixture.reject()
    do { _ = try await client.downloadManifest(appID: 42, source: "Sushi"); throw TestFailure(description: "HTTP failure accepted") } catch is LuaToolsAPIError { }
    do { _ = try await client.checkSources(appID: 0); throw TestFailure(description: "invalid AppID accepted") } catch is LuaToolsAPIError { }
}
