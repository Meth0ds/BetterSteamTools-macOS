import Foundation
@_spi(Testing) import LuaToolsMacCore

private final class MemoryCredentials: LuaToolsCredentialStore, @unchecked Sendable {
    private let lock = NSLock(); private var data: Data?
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ value: Data) throws { lock.lock(); defer { lock.unlock() }; data = value }
    func remove() throws { lock.lock(); defer { lock.unlock() }; data = nil }
}
private actor AuthFixture {
    private(set) var requests: [URLRequest] = []
    var rejected = false
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if rejected { return (Data(), 401) }
        switch request.url?.path {
        case "/api/auth/code/redeem": return (Data(#"{"token":"fixture-magic"}"#.utf8), 200)
        case "/auth/v1/verify": return (Data(#"{"access_token":"first-access","refresh_token":"first-refresh","expires_in":1,"user":{"email":"fixture@example.test","user_metadata":{"name":"Fixture"}}}"#.utf8), 200)
        case "/auth/v1/token":
            try await Task.sleep(for: .milliseconds(80))
            return (Data(#"{"access_token":"refreshed","refresh_token":"second-refresh","expires_in":3600}"#.utf8), 200)
        default: return (Data(), 404)
        }
    }
    func setRejected() { rejected = true }
    func captured() -> [URLRequest] { requests }
}

func testAuthentication() async throws {
    let store = MemoryCredentials(), fixture = AuthFixture()
    let auth = LuaToolsAuthentication(store: store, transport: { try await fixture.send($0) })
    let initial = try await auth.account(); try check(initial == nil, "guest session begins empty")
    do { _ = try await auth.signIn(code: "bad"); throw TestFailure(description: "invalid code accepted") } catch is LuaToolsAuthenticationError { }
    let account = try await auth.signIn(code: " a1b2c3 ")
    try check(account.displayName == "Fixture" && account.email == "fixture@example.test", "code flow retains real account metadata")
    let captured = await fixture.captured()
    let redeem = try JSONSerialization.jsonObject(with: captured[0].httpBody!) as? [String: String]
    let verify = try JSONSerialization.jsonObject(with: captured[1].httpBody!) as? [String: String]
    try check(captured.count == 2 && redeem?["code"] == "A1B2C3" && verify?["token_hash"] == "fixture-magic", "code and magic-link requests follow Windows contract")
    try check(captured[0].value(forHTTPHeaderField: "apikey") == nil && captured[1].value(forHTTPHeaderField: "apikey") != nil, "Supabase key is sent only to Supabase")
    async let a = auth.accessToken(); async let b = auth.accessToken()
    let values = try await (a, b)
    try check(values.0 == "refreshed" && values.1 == "refreshed", "concurrent calls share refreshed token")
    let after = await fixture.captured()
    try check(after.filter { $0.url?.path == "/auth/v1/token" }.count == 1, "concurrent refresh is single-flight")
    let restored = LuaToolsAuthentication(store: store, transport: { try await fixture.send($0) })
    let restoredAccount = try await restored.account(), restoredToken = try await restored.accessToken()
    try check(restoredAccount == account, "account metadata survives restart")
    try check(restoredToken == "refreshed", "valid persisted access token is reused")
    try await auth.signOut()
    let signedOut = try await restored.account(); try check(signedOut == nil, "sign out removes persisted credentials")
    do { _ = try await restored.accessToken(); throw TestFailure(description: "signed-out token returned") } catch is LuaToolsAuthenticationError { }
    await fixture.setRejected()
    do { _ = try await auth.signIn(code: "A1B2C3"); throw TestFailure(description: "rejected code accepted") } catch is LuaToolsAuthenticationError { }
    let failed = try await auth.account(); try check(failed == nil, "failed login does not store credentials")
    let racingStore = MemoryCredentials(), racingFixture = AuthFixture()
    let racing = LuaToolsAuthentication(store: racingStore, transport: { try await racingFixture.send($0) })
    _ = try await racing.signIn(code: "A1B2C3")
    let pending = Task { try await racing.accessToken() }
    try await Task.sleep(for: .milliseconds(20))
    try await racing.signOut()
    do { _ = try await pending.value; throw TestFailure(description: "refresh returned after sign out") } catch is CancellationError { } catch is LuaToolsAuthenticationError { }
    let afterRace = try await racing.account(); try check(afterRace == nil, "cancelled refresh cannot restore signed-out session")
}
