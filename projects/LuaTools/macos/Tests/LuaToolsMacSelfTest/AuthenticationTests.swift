import Foundation
import Darwin
@_spi(Testing) import LuaToolsMacCore

private final class MemoryCredentials: LuaToolsCredentialStore, @unchecked Sendable {
    private let lock = NSLock(); private var data: Data?
    private let refreshLock = NSLock(); private var refreshHeld = false
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func compareExchange(expected: Data?, desired: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard data == expected else { return false }
        data = desired; return true
    }
    private func attempt() -> Bool { refreshLock.lock(); defer { refreshLock.unlock() }; if refreshHeld { return false }; refreshHeld = true; return true }
    private func releaseRefresh() { refreshLock.lock(); defer { refreshLock.unlock() }; refreshHeld = false }
    func acquireRefreshLock() async throws -> any LuaToolsRefreshLease {
        while !attempt() { try await Task.sleep(for: .milliseconds(5)) }
        return MemoryLease { self.releaseRefresh() }
    }
}
private final class MemoryLease: LuaToolsRefreshLease, @unchecked Sendable {
    private let lock = NSLock(); private var operation: (() -> Void)?
    init(_ operation: @escaping () -> Void) { self.operation = operation }
    func release() { lock.lock(); defer { lock.unlock() }; operation?(); operation = nil }
    deinit { release() }
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

func authLockChild(root: URL, crash: Bool) async throws {
    let lease = try await LuaToolsAccountFileLock(file: root.appendingPathComponent("account.lock")).acquire()
    defer { lease.release() }
    try Data("ready".utf8).write(to: root.appendingPathComponent("ready"))
    if crash { _exit(86) }
    let deadline = Date().addingTimeInterval(8)
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("release").path) && Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
}
func testAccountFileLock(root: URL) async throws {
    let folder = root.appendingPathComponent("auth-lock")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let lock = LuaToolsAccountFileLock(file: folder.appendingPathComponent("account.lock"))
    let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = ["--auth-lock-hold", folder.path]
    try child.run()
    defer { try? Data("release".utf8).write(to: folder.appendingPathComponent("release")) }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path) && child.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try check(child.isRunning && FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path), "child process holds account refresh lock")
    let waiter = Task { try await lock.acquire() }
    try await Task.sleep(for: .milliseconds(100)); waiter.cancel()
    do { let lease = try await waiter.value; lease.release(); throw TestFailure(description: "account lock did not wait") } catch is CancellationError { }
    try Data("release".utf8).write(to: folder.appendingPathComponent("release")); child.waitUntilExit()
    try check(child.terminationStatus == 0, "lock holder exits cleanly")
    let lease = try await lock.acquire(); lease.release()
    try FileManager.default.removeItem(at: folder.appendingPathComponent("ready"))
    let crashed = Process(); crashed.executableURL = child.executableURL; crashed.arguments = ["--auth-lock-crash", folder.path]
    try crashed.run(); crashed.waitUntilExit(); try check(crashed.terminationStatus == 86, "lock holder terminated abruptly")
    let recovered = try await lock.acquire(); recovered.release()
    let link = folder.appendingPathComponent("link.lock")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("account.lock"))
    do { let lease = try await LuaToolsAccountFileLock(file: link).acquire(); lease.release(); throw TestFailure(description: "symlink lock accepted") } catch is LuaToolsError { }
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
    let sharedStore = MemoryCredentials(), sharedFixture = AuthFixture()
    let firstProcess = LuaToolsAuthentication(store: sharedStore, transport: { try await sharedFixture.send($0) })
    let secondProcess = LuaToolsAuthentication(store: sharedStore, transport: { try await sharedFixture.send($0) })
    _ = try await firstProcess.signIn(code: "A1B2C3")
    let inFlight = Task { try await firstProcess.accessToken() }
    try await Task.sleep(for: .milliseconds(20))
    try await secondProcess.signOut()
    do { _ = try await inFlight.value; throw TestFailure(description: "other process restored signed-out session") } catch is LuaToolsAuthenticationError { }
    let sharedResult = try await firstProcess.account(); try check(sharedResult == nil, "sign-out in another process prevents refresh resurrection")
    _ = try await firstProcess.signIn(code: "A1B2C3")
    let beforeRefresh = await sharedFixture.captured().filter { $0.url?.path == "/auth/v1/token" }.count
    async let firstToken = firstProcess.accessToken(); async let secondToken = secondProcess.accessToken()
    let pair = try await (firstToken, secondToken)
    let refreshes = await sharedFixture.captured().filter { $0.url?.path == "/auth/v1/token" }.count
    try check(pair.0 == "refreshed" && pair.1 == "refreshed" && refreshes == beforeRefresh + 1, "separate instances serialize refresh and reuse the rotated token")
}
