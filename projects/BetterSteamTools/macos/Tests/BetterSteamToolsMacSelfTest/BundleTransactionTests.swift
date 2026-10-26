import Foundation
import CryptoKit
import Darwin
import BetterSteamToolsMacCore

private struct BundleState: Equatable {
    var files: [String: Data] = [:]
    var modes: [String: UInt16] = [:]
    var links: [String: String] = [:]
}
private func capture(_ originalURL: URL) throws -> BundleState {
    guard let resolved = realpath(originalURL.path, nil) else { throw TestFailure(description: "fixture realpath") }
    defer { free(resolved) }
    let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    var result = BundleState()
    let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
    var urls = [root]; for case let url as URL in walk { urls.append(url) }
    for url in urls {
        let relative = url == root ? "." : String(url.path.dropFirst(root.path.count + 1))
        var info = stat(); guard lstat(url.path, &info) == 0 else { throw TestFailure(description: "fixture lstat") }
        result.modes[relative] = info.st_mode
        if info.st_mode & S_IFMT == S_IFREG { result.files[relative] = try Data(contentsOf: url) }
        if info.st_mode & S_IFMT == S_IFLNK { result.links[relative] = try FileManager.default.destinationOfSymbolicLink(atPath: url.path) }
    }
    return result
}
private func fixturePaths(_ root: URL) -> SteamPaths { SteamPaths(steamApp: root.appendingPathComponent("Steam.app"), userData: root.appendingPathComponent("SteamData")) }
private func fixtureInstaller(_ root: URL, observer: @escaping SteamBundleInstaller.Observer = { _ in }) -> SteamBundleInstaller {
    SteamBundleInstaller(paths: fixturePaths(root), backupURL: root.appendingPathComponent("state/Info.plist"),
                         signer: fixtureSigner, isSteamRunning: { false }, observer: observer)
}
private func fixtureSigner(_ app: URL) throws {
    // Simulate the executable/signature writes made by real codesign. A plist-
    // only rollback cannot pass these assertions.
    let executable = app.appendingPathComponent("Contents/MacOS/steam_osx")
    try (Data(contentsOf: executable) + Data("-signed".utf8)).write(to: executable)
    try Data("replacement-code-signature-seal".utf8).write(to: app.appendingPathComponent("Contents/_CodeSignature/CodeResources"))
}
private func makeFixture(_ root: URL) throws {
    let fm = FileManager.default, paths = fixturePaths(root)
    for directory in ["Contents/MacOS", "Contents/_CodeSignature", "Contents/Resources"] {
        try fm.createDirectory(at: paths.steamApp.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.bst.fixture", "CFBundleExecutable": "steam_osx",
        "LSEnvironment": ["DYLD_INSERT_LIBRARIES": "/other/notproton.dylib:/other/extra.dylib", "PRESERVED": "yes"]], format: .binary, options: 0).write(to: paths.infoPlist)
    let executable = paths.steamExecutable
    try machO().write(to: executable)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try Data("original-signature-seal".utf8).write(to: paths.steamApp.appendingPathComponent("Contents/_CodeSignature/CodeResources"))
    try Data("resource-data".utf8).write(to: paths.steamApp.appendingPathComponent("Contents/Resources/preserved.bin"))
    try fm.createSymbolicLink(atPath: paths.steamApp.appendingPathComponent("Contents/Resources/resource-link").path, withDestinationPath: "preserved.bin")
    let dylib = root.appendingPathComponent("payload.dylib")
    try machO(fileType: 6).write(to: dylib)
    let key = Curve25519.Signing.PrivateKey()
    let manifest = try installerApproval(paths: paths, dylib: dylib, key: key)
    try manifest.envelope.write(to: root.appendingPathComponent("approval.json"))
    try key.publicKey.rawRepresentation.write(to: root.appendingPathComponent("approval-public-key"))
}
private func fixtureApproval(_ root: URL) throws -> SteamBuildManifest {
    try SteamBuildManifest.load(from: root.appendingPathComponent("approval.json"), trustedKeys: ["fixture": Data(contentsOf: root.appendingPathComponent("approval-public-key"))])
}
func runTransactionCrashChild(_ args: [String]) throws {
    guard args.count == 3, let point = SteamBundleInstaller.Checkpoint(rawValue: args[1]) else { throw TestFailure(description: "crash fixture arguments") }
    let root = URL(fileURLWithPath: args[0], isDirectory: true)
    let installer = fixtureInstaller(root, observer: { if $0 == point { _exit(91) } })
    if args[2] == "install" { try installer.install(dylib: root.appendingPathComponent("payload.dylib"), manifest: fixtureApproval(root)) }
    else if args[2] == "uninstall" { try installer.uninstall() }
    else { throw TestFailure(description: "unknown crash operation") }
    throw TestFailure(description: "crash checkpoint was never reached")
}
private func crash(_ root: URL, at point: SteamBundleInstaller.Checkpoint, operation: String) throws {
    guard let executable = Bundle.main.executableURL else { throw TestFailure(description: "cannot locate self-test executable") }
    let process = Process(); process.executableURL = executable
    process.arguments = ["--transaction-crash", root.path, point.rawValue, operation]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run(); process.waitUntilExit()
    try check(process.terminationReason == .exit && process.terminationStatus == 91, "child must reach \(operation) checkpoint \(point.rawValue), got \(process.terminationStatus)")
}
func testTransactionRecovery(root: URL) throws {
    let checkpoints: [SteamBundleInstaller.Checkpoint] = [.staging, .prepared, .swapped, .receiptPersisted, .committed]
    for operation in ["install", "uninstall"] {
        for point in checkpoints {
            let fixture = root.appendingPathComponent("crash-\(operation)-\(point.rawValue)")
            try makeFixture(fixture)
            let installer = fixtureInstaller(fixture)
            let original = try capture(fixturePaths(fixture).steamApp)
            if operation == "uninstall" { try installer.install(dylib: fixture.appendingPathComponent("payload.dylib"), manifest: fixtureApproval(fixture)) }
            let before = try capture(fixturePaths(fixture).steamApp)
            try crash(fixture, at: point, operation: operation)
            try installer.recover(); try installer.recover()
            let current = try capture(fixturePaths(fixture).steamApp)
            if point == .committed {
                if operation == "install" {
                    try check(current != original && current.files["Contents/MacOS/BetterSteamTools.dylib"] != nil, "committed install survives crash recovery")
                    try installer.uninstall()
                } else { try check(current == original, "committed uninstall restores executable and signature seal exactly") }
            } else {
                try check(current == before, "interrupted \(operation) at \(point.rawValue) restores the entire prior bundle")
                if operation == "uninstall" { try installer.uninstall() }
            }
            try check(capture(fixturePaths(fixture).steamApp) == original, "final exact fixture restoration")
            try check(!FileManager.default.fileExists(atPath: fixture.appendingPathComponent("state/transaction-v2.json").path), "recovery clears settled journal")
        }
    }
    let conflict = root.appendingPathComponent("crash-external-change")
    try makeFixture(conflict)
    try crash(conflict, at: .swapped, operation: "install")
    let resource = fixturePaths(conflict).steamApp.appendingPathComponent("Contents/Resources/preserved.bin")
    let original = try Data(contentsOf: resource)
    try Data("external post-crash change".utf8).write(to: resource)
    try rejects("recovery must not overwrite a later external change") { try fixtureInstaller(conflict).recover() }
    try check(Data(contentsOf: resource) == Data("external post-crash change".utf8), "conflicting external content remains untouched")
    try original.write(to: resource)
    try fixtureInstaller(conflict).recover()
    let failing = root.appendingPathComponent("signer-binary-failure")
    try makeFixture(failing)
    let before = try capture(fixturePaths(failing).steamApp)
    let installer = SteamBundleInstaller(paths: fixturePaths(failing), backupURL: failing.appendingPathComponent("state/Info.plist"), signer: { app in
        try fixtureSigner(app); throw BundleError.signingFailed("fixture failed after modifying executable and signature")
    }, isSteamRunning: { false })
    try rejects("failed signing must roll back") { try installer.install(dylib: failing.appendingPathComponent("payload.dylib"), manifest: fixtureApproval(failing)) }
    try check(capture(fixturePaths(failing).steamApp) == before, "failed signing leaves original executable, resources and signature bytes intact")
}

func testRealCodeSigning(root: URL, dylib: URL) throws {
    let fm = FileManager.default, fixture = root.appendingPathComponent("real-code-signing")
    try makeFixture(fixture)
    let paths = fixturePaths(fixture)
    try fm.removeItem(at: paths.steamExecutable)
    try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: paths.steamExecutable)
    // The fixture's synthetic signature is replaced by actual codesign.
    try SteamBundleInstaller.adHocSign(paths.steamApp)
    let original = try capture(paths.steamApp)
    let approval = try installerApproval(paths: paths, dylib: dylib)
    let installer = SteamBundleInstaller(paths: paths, backupURL: fixture.appendingPathComponent("state/Info.plist"), isSteamRunning: { false })
    try installer.install(dylib: dylib, manifest: approval)
    let verify = Process(); verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    verify.arguments = ["--verify", "--strict", paths.steamApp.path]
    try verify.run(); verify.waitUntilExit()
    try check(verify.terminationStatus == 0, "real codesign verifies installed bundle")
    try installer.uninstall()
    try check(capture(paths.steamApp) == original, "real codesign installation uninstalls to the exact original signed executable and resources")
}
