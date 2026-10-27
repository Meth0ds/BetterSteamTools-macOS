import Foundation
import Darwin
@_spi(Testing) import LuaToolsMacCore

func pluginCrashChild(destination: URL, archive: URL, operation: String, stop: Int) throws {
    let installer = PluginInstaller(destination: destination, bundledDirectory: nil, checkpoint: { if $0 == stop { _exit(86) } })
    switch operation {
    case "install": try installer.install(zip: archive)
    case "rollback": try installer.rollback()
    case "uninstall": try installer.uninstall()
    default: throw TestFailure(description: "unknown plugin operation")
    }
    throw TestFailure(description: "plugin child did not reach checkpoint")
}

func testPluginInstaller(root: URL) throws {
    let fm = FileManager.default
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("plugin-macos")
    let fixtures = root.appendingPathComponent("plugin-fixtures")
    try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
    func makeArchive(_ version: Int) throws -> URL {
        let folder = fixtures.appendingPathComponent("source-\(version)")
        try fm.copyItem(at: source, to: folder)
        let js = folder.appendingPathComponent("public/luatools.js")
        var data = try Data(contentsOf: js); data.append(Data("\n// fixture version \(version)\n".utf8)); try data.write(to: js)
        let archive = fixtures.appendingPathComponent("plugin-\(version).zip")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = folder
        zip.arguments = ["-q", "-r", archive.path, "plugin.json", "public", "backend", "README.md"]
        try zip.run(); zip.waitUntilExit(); try check(zip.terminationStatus == 0, "create real plugin archive")
        return archive
    }
    let archives = try (0...2).map(makeArchive)
    func contents(_ destination: URL) throws -> Data { try Data(contentsOf: destination.appendingPathComponent("public/luatools.js")) }
    func expected(_ version: Int) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent("source-\(version)/public/luatools.js")) }
    func crash(_ destination: URL, _ operation: String, _ point: Int) throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--plugin-crash", destination.path, archives[2].path, operation, String(point)]
        try child.run(); child.waitUntilExit(); try check(child.terminationStatus == 86, "plugin \(operation) checkpoint \(point)")
    }
    let destination = root.appendingPathComponent("plugin-active")
    let installer = PluginInstaller(destination: destination, bundledDirectory: source, checkpoint: nil)
    try check(installer.resolveActiveDirectory() == source, "bundled plugin used before installation")
    try installer.install(zip: archives[0]); try installer.install(zip: archives[1])
    try installer.install(zip: archives[1]); try installer.rollback()
    try check(contents(destination) == expected(0), "identical update preserves previous version")
    try installer.rollback(); try check(contents(destination) == expected(1), "rollback is reversible")
    var rejected = false
    do { try installer.install(zip: archives[2], expectedSHA256: String(repeating: "0", count: 64)) } catch { rejected = true }
    try check(rejected && contents(destination) == expected(1), "bad digest preserves installed plugin")
    try installer.uninstall(); try check(installer.resolveActiveDirectory() == nil, "uninstall does not reactivate bundled plugin")
    for operation in ["install", "rollback", "uninstall"] {
        let points = operation == "install" ? Array(0...6) : [1, 2, 3, 5, 6]
        for point in points {
            let path = root.appendingPathComponent("crash-\(operation)-\(point)")
            let instance = PluginInstaller(destination: path, bundledDirectory: nil, checkpoint: nil)
            try instance.install(zip: archives[0]); try instance.install(zip: archives[1])
            try crash(path, operation, point); try instance.recover()
            let committed = point >= 3
            if operation == "uninstall" && committed { try check(instance.resolveActiveDirectory() == nil, "committed uninstall recovered") }
            else {
                let version = operation == "install" && committed ? 2 : (operation == "rollback" && committed ? 0 : 1)
                try check(contents(path) == expected(version), "\(operation) recovers consistently at \(point)")
            }
        }
    }
    let conflict = root.appendingPathComponent("plugin-conflict")
    let conflictingInstaller = PluginInstaller(destination: conflict, bundledDirectory: nil, checkpoint: nil)
    try conflictingInstaller.install(zip: archives[0]); try crash(conflict, "install", 2)
    let changed = conflict.appendingPathComponent("public/luatools.js")
    let external = Data("external edit".utf8); try external.write(to: changed)
    rejected = false
    do { try conflictingInstaller.recover() } catch { rejected = true }
    try check(rejected && Data(contentsOf: changed) == external, "recovery preserves externally modified plugin")
    let foreign = root.appendingPathComponent("foreign-plugin")
    try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
    rejected = false
    do { try PluginInstaller(destination: foreign, bundledDirectory: nil, checkpoint: nil).install(zip: archives[0]) } catch { rejected = true }
    try check(rejected && fm.fileExists(atPath: foreign.path), "unmanaged plugin is preserved")
}
