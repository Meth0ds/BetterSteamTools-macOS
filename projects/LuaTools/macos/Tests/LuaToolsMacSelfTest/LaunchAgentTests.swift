import Foundation
@_spi(Testing) import LuaToolsMacCore

private final class AgentRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var failNextBootstrap = false
    private var commands: [[String]] = []
    func failOnce() { lock.lock(); defer { lock.unlock() }; failNextBootstrap = true }
    func run(_ arguments: [String]) -> Int32 {
        lock.lock(); defer { lock.unlock() }; commands.append(arguments)
        switch arguments.first {
        case "print": return loaded ? 0 : 1
        case "bootout": loaded = false; return 0
        case "bootstrap":
            if failNextBootstrap { failNextBootstrap = false; return 1 }
            loaded = true; return 0
        default: return 2
        }
    }
    func isLoaded() -> Bool { lock.lock(); defer { lock.unlock() }; return loaded }
    func calls() -> [[String]] { lock.lock(); defer { lock.unlock() }; return commands }
}

func testLaunchAgent(root: URL) throws {
    let directory = root.appendingPathComponent("LaunchAgents")
    let executable = root.appendingPathComponent("LuaTools.app/Contents/MacOS/LuaToolsDaemon")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture executable".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let runner = AgentRunner()
    let installer = LaunchAgentInstaller(directory: directory, uid: 501, runner: { runner.run($0) })
    let file = try installer.install(executable: executable)
    let original = try Data(contentsOf: file)
    let plist = try PropertyListSerialization.propertyList(from: original, format: nil) as! [String: Any]
    try check(plist["ProgramArguments"] as? [String] == [executable.path] && plist["KeepAlive"] as? Bool == true && runner.isLoaded(), "agent starts the packaged daemon at login")
    _ = try installer.install(executable: executable)
    try check(runner.calls().contains(["bootout", "gui/501/com.luatools.macos"]), "updating a loaded agent stops the previous instance")
    runner.failOnce()
    var failed = false
    do { _ = try installer.install(executable: executable) } catch { failed = true }
    try check(failed && Data(contentsOf: file) == original && runner.isLoaded(), "failed bootstrap restores the previous agent and restarts it")
    try installer.uninstall()
    try check(!FileManager.default.fileExists(atPath: file.path) && !runner.isLoaded(), "uninstall stops and removes the owned agent")
    try Data("foreign file".utf8).write(to: file)
    let calls = runner.calls().count
    failed = false
    do { _ = try installer.install(executable: executable) } catch { failed = true }
    try check(failed && Data(contentsOf: file) == Data("foreign file".utf8) && runner.calls().count == calls, "foreign agent files are preserved")
}
