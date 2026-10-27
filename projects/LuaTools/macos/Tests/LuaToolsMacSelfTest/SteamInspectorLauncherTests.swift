import Foundation
@_spi(Testing) import LuaToolsMacCore

private final class LaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(URL, [String])] = []
    func append(_ app: URL, _ arguments: [String]) { lock.lock(); defer { lock.unlock() }; values.append((app, arguments)) }
    func snapshot() -> [(URL, [String])] { lock.lock(); defer { lock.unlock() }; return values }
}

func testSteamInspectorLauncher(root: URL) throws {
    let app = root.appendingPathComponent("Steam.app")
    let paths = SteamMacPaths(steamApp: app, userData: root)
    try FileManager.default.createDirectory(at: paths.infoPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: paths.infoPlist)
    let recorder = LaunchRecorder()
    let launch = SteamInspectorLauncher(paths: paths, port: 8080, running: { false }, listeners: { _ in [] },
                                        authorize: { _, _ in }, open: { recorder.append($0, $1) })
    try check(launch.start() == .launched, "closed Steam is launched with inspector")
    let calls = recorder.snapshot()
    try check(calls.count == 1 && calls[0].0 == app && calls[0].1 == ["-cef-enable-debugging", "-devtools-port", "8080"], "native Steam arguments are passed without a shell")
    let running = SteamInspectorLauncher(paths: paths, port: 8080, running: { true }, listeners: { _ in [] },
                                         authorize: { _, _ in }, open: { recorder.append($0, $1) })
    try check(running.start() == .restartRequired && recorder.snapshot().count == 1, "running Steam is never stopped or relaunched implicitly")
    let owner = InspectorListenerOwner(pid: 123, executable: "/fixture/Steam Helper", loopbackOnly: true)
    let ready = SteamInspectorLauncher(paths: paths, port: 8080, running: { true }, listeners: { _ in [owner] },
                                       authorize: { endpoint, _ in guard endpoint.port == 8080 else { throw LuaToolsError.invalidRequest } }, open: { recorder.append($0, $1) })
    try check(ready.start() == .inspectorAvailable && recorder.snapshot().count == 1, "authorized existing inspector is reused")
    let foreign = SteamInspectorLauncher(paths: paths, port: 8080, running: { true }, listeners: { _ in [owner] },
                                         authorize: { _, _ in throw LuaToolsError.invalidRequest }, open: { recorder.append($0, $1) })
    var rejected = false
    do { _ = try foreign.start() } catch { rejected = true }
    try check(rejected && recorder.snapshot().count == 1, "foreign listener cannot trigger a launch or connection")
}
