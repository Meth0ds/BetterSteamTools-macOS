import Foundation
import Darwin
@_spi(Testing) import LuaToolsMacCore

private let oldLua = Data("old Lua".utf8), newLua = Data("new Lua".utf8)
private let oldManifest = Data("old manifest".utf8), newManifest = Data("new manifest".utf8)
private let newSecondManifest = Data("new second manifest".utf8)

func transactionChild(root: URL, stop: Int) throws {
    let paths = SteamMacPaths(steamApp: root.appendingPathComponent("Steam.app"), userData: root)
    let transaction = try PackageTransaction(paths: paths, checkpoint: { index in if index == stop { _exit(86) } })
    try transaction.apply([
        .init(relativePath: "config/stplug-in/42.lua", data: newLua),
        .init(relativePath: "depotcache/123_456.manifest", data: newManifest),
        .init(relativePath: "depotcache/124_457.manifest", data: newSecondManifest),
    ])
    throw TestFailure(description: "child did not reach transaction checkpoint")
}

func transactionHoldingChild(root: URL) throws {
    let paths = SteamMacPaths(steamApp: root.appendingPathComponent("Steam.app"), userData: root)
    let ready = root.appendingPathComponent("ready"), release = root.appendingPathComponent("release")
    let transaction = try PackageTransaction(paths: paths, checkpoint: { index in
        if index != 0 { return }
        try? Data("ready".utf8).write(to: ready)
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: release.path) && Date() < deadline { usleep(20_000) }
        if !FileManager.default.fileExists(atPath: release.path) { _exit(87) }
    })
    try transaction.apply([.init(relativePath: "config/stplug-in/42.lua", data: newLua)])
}

func testPackageTransactionCrashRecovery(root: URL) throws {
    let steam = root.appendingPathComponent("transaction-steam", isDirectory: true)
    let paths = SteamMacPaths(steamApp: steam.appendingPathComponent("Steam.app"), userData: steam)
    try FileManager.default.createDirectory(at: paths.stPlugin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.depotCache, withIntermediateDirectories: true)
    let lua = paths.stPlugin.appendingPathComponent("42.lua")
    let manifest = paths.depotCache.appendingPathComponent("123_456.manifest")
    let added = paths.depotCache.appendingPathComponent("124_457.manifest")
    func reset() throws {
        try oldLua.write(to: lua); try oldManifest.write(to: manifest)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: lua.path)
        if FileManager.default.fileExists(atPath: added.path) { try FileManager.default.removeItem(at: added) }
    }
    func crash(_ point: Int) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--transaction-crash", steam.path, String(point)]
        try child.run(); child.waitUntilExit()
        try check(child.terminationStatus == 86, "transaction child exited at checkpoint \(point)")
    }
    for point in [-3, -2, -1, 0, 1, 2, 3, 4] {
        try reset(); try crash(point)
        try PackageTransaction(paths: paths).recover()
        let committed = point == 4
        try check(Data(contentsOf: lua) == (committed ? newLua : oldLua), "Lua restored or committed after checkpoint \(point)")
        try check(Data(contentsOf: manifest) == (committed ? newManifest : oldManifest), "existing manifest restored or committed after checkpoint \(point)")
        try check(FileManager.default.fileExists(atPath: added.path) == committed, "new manifest removed on rollback after checkpoint \(point)")
        let permissions = try FileManager.default.attributesOfItem(atPath: lua.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o640, "Lua permissions survive transaction recovery")
        let temporary = try [paths.stPlugin, paths.depotCache].flatMap { try FileManager.default.contentsOfDirectory(atPath: $0.path) }.filter { $0.hasPrefix(".luatools-write-") || $0.hasPrefix(".luatools-restore-") }
        try check(temporary.isEmpty, "interrupted staging files are cleaned after checkpoint \(point)")
    }
    try reset(); try crash(1)
    try Data("external edit".utf8).write(to: lua)
    var conflict = false
    do { try PackageTransaction(paths: paths).recover() } catch { conflict = true }
    try check(conflict && Data(contentsOf: lua) == Data("external edit".utf8), "external edit is preserved and recovery reports a conflict")
    try newLua.write(to: lua)
    try PackageTransaction(paths: paths).recover()
    try check(Data(contentsOf: lua) == oldLua && Data(contentsOf: manifest) == oldManifest, "conflicted journal can be recovered after resolution")
    try reset()
    let ready = steam.appendingPathComponent("ready"), release = steam.appendingPathComponent("release")
    defer { try? Data("release".utf8).write(to: release) }
    let first = Process(); first.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    first.arguments = ["--transaction-hold", steam.path]; try first.run()
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: ready.path) && first.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    try check(FileManager.default.fileExists(atPath: ready.path), "first process holds a prepared transaction")
    let second = Process(); second.executableURL = first.executableURL
    second.arguments = ["--transaction-crash", steam.path, "4"]; try second.run()
    Thread.sleep(forTimeInterval: 0.2)
    try check(first.isRunning && second.isRunning && Data(contentsOf: lua) == oldLua, "another process waits for the transaction lock")
    try Data("release".utf8).write(to: release)
    first.waitUntilExit(); second.waitUntilExit()
    try check(first.terminationStatus == 0 && second.terminationStatus == 86, "both serialized processes complete their expected path")
    try PackageTransaction(paths: paths).recover()
    try check(Data(contentsOf: lua) == newLua && Data(contentsOf: manifest) == newManifest, "serialized transaction results remain coherent")
    try reset()
    let priorDate = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.modificationDate: priorDate], ofItemAtPath: lua.path)
    try PackageTransaction(paths: paths).apply([.init(relativePath: "config/stplug-in/42.lua", data: oldLua)])
    let unchangedDate = try FileManager.default.attributesOfItem(atPath: lua.path)[.modificationDate] as? Date
    try check(unchangedDate == priorDate, "identical content does not rewrite an existing Lua file")
}
