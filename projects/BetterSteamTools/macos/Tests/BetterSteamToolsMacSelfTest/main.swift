import Foundation
import CryptoKit
import BetterSteamToolsMacCore
import BSTBuildApproval

struct TestFailure: Error, CustomStringConvertible { let description: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(description: message) }
}
func rejects(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw TestFailure(description: message)
}
func machO(cpu: UInt32 = 0x0100000c, fileType: UInt32 = 2, is64: Bool = true) -> Data {
    var result = Data()
    for value: UInt32 in [is64 ? 0xfeedfacf : 0xfeedface, cpu, 0, fileType, 0, 0, 0] + (is64 ? [0] : []) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
    }
    return result
}
func pe() -> Data {
    var data = Data(repeating: 0, count: 88)
    data[0] = 0x4d; data[1] = 0x5a; data[60] = 64
    data[64] = 0x50; data[65] = 0x45; data[68] = 0x64; data[69] = 0x86; data[86] = 0x02
    return data
}
func testKeyValues() throws {
    let text = "// a quoted comment \"path\" \"/wrong\"\n\"root\" { \"name\" \"One \\\"quote\\\"\" \"child\" { \"name\" \"nested\" } }\n"
    let document = try KeyValuesDocument(text)
    try check(document.entry(at: ["root", "name"])?.value == "One \"quote\"", "quoted tokens")
    let replaced = try document.setting(["root", "child", "name"], to: "new")
    try check(replaced.contains("// a quoted comment"), "comments survive edits")
    try check(KeyValuesDocument(replaced).entry(at: ["root", "name"])?.value == "One \"quote\"", "unrelated same-name key survives")
    let added = try document.setting(["root", "new", "leaf"], to: "value")
    try check(KeyValuesDocument(added).entry(at: ["root", "new", "leaf"])?.value == "value", "create intermediate objects")
    try rejects("unclosed objects rejected") { _ = try KeyValuesDocument("root { key value") }
    try rejects("duplicate selectors rejected") { _ = try KeyValuesDocument("root { key a key b }").entry(at: ["root", "key"]) }
}
func testExecutableImages(root: URL) throws {
    try check(ExecutableImage.machOSlices(machO()).first?.isSupportedMacExecutable == true, "arm64 main executable")
    try check(ExecutableImage.machOSlices(machO(fileType: 6)).first?.isSupportedMacExecutable == false, "dylibs are not games")
    try check(ExecutableImage.machOSlices(machO(cpu: 7, is64: false)).first?.isSupportedMacExecutable == false, "32-bit macOS is not supported")
    try rejects("truncated Mach-O rejected") { _ = try ExecutableImage.machOSlices(Data([0xcf, 0xfa, 0xed, 0xfe])) }
    let executable = root.appendingPathComponent("game.exe")
    try pe().write(to: executable)
    try check(ExecutableImage.isWindowsExecutable(at: executable), "PE executable")
    try Data("not an executable".utf8).write(to: executable)
    try check(!ExecutableImage.isWindowsExecutable(at: executable), ".exe extension alone is not proof")
    let sparse = root.appendingPathComponent("large-macho")
    try machO().write(to: sparse)
    let handle = try FileHandle(forWritingTo: sparse)
    try handle.truncate(atOffset: 4 * 1024 * 1024 * 1024)
    try handle.close()
    try check(ExecutableImage.machOSlices(at: sparse).first?.isSupportedMacExecutable == true, "large sparse Mach-O reads bounded headers")
    let thin = machO()
    func big(_ value: UInt32) -> Data { var big = value.bigEndian; return withUnsafeBytes(of: &big) { Data($0) } }
    let universal = big(0xcafebabe) + big(1) + big(0x0100000c) + big(0) + big(28) + big(UInt32(thin.count)) + big(0) + thin
    try universal.write(to: sparse)
    try check(ExecutableImage.machOSlices(at: sparse) == ExecutableImage.machOSlices(universal), "file and in-memory universal Mach-O agree")
    try universal.dropLast().write(to: sparse)
    try check(ExecutableImage.machOSlices(at: sparse).isEmpty, "truncated universal slice rejected")
}
func testRouting(root: URL) throws {
    let paths = SteamPaths(steamApp: root.appendingPathComponent("Steam.app"), userData: root)
    let library = SteamLibrary(root: root)
    let native = library.common.appendingPathComponent("Native/Game.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
    try machO().write(to: native.appendingPathComponent("Game"))
    let info: [String: String] = ["CFBundleExecutable": "Game"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: native.deletingLastPathComponent().appendingPathComponent("Info.plist"))
    for (id, name) in [(42, "Native"), (43, "Windows"), (44, "HelperOnly")] {
        try "\"AppState\" { \"appid\" \"\(id)\" \"installdir\" \"\(name)\" }".write(to: library.steamapps.appendingPathComponent("appmanifest_\(id).acf"), atomically: true, encoding: .utf8)
    }
    for name in ["Windows", "HelperOnly"] { try FileManager.default.createDirectory(at: library.common.appendingPathComponent(name), withIntermediateDirectories: true) }
    try pe().write(to: library.common.appendingPathComponent("Windows/game.exe"))
    try machO(fileType: 6).write(to: library.common.appendingPathComponent("Windows/library.dylib"))
    try machO(fileType: 6).write(to: library.common.appendingPathComponent("HelperOnly/library.dylib"))
    let router = GameRouter()
    try check(router.plan(appID: 42, paths: paths).mode == .native, "native game routes natively")
    try check(router.plan(appID: 43, paths: paths).useNotProton, "Windows plus native DLL still routes through CrossOver")
    try check(router.plan(appID: 44, paths: paths).mode == .auto, "a DLL does not classify an app as native")
    try check(router.plan(appID: 42, override: .crossover, paths: paths).useNotProton, "manual override")
    try "\"AppState\" { \"appid\" \"99\" \"installdir\" \"../../outside\" }".write(to: library.steamapps.appendingPathComponent("appmanifest_99.acf"), atomically: true, encoding: .utf8)
    try check(VDF.appManifest(appID: 99, library: library) == nil, "manifest cannot leave common directory")
}
func testSignedManifest(root: URL) throws {
    let paths = SteamPaths(steamApp: root.appendingPathComponent("Steam.app"), userData: root)
    try FileManager.default.createDirectory(at: paths.clientDirectory, withIntermediateDirectories: true)
    let dylib = root.appendingPathComponent("signed-payload.dylib")
    try machO(fileType: 6).write(to: dylib)
    var hashes: [String: String] = [:]
    for file in ["steam_osx", "steamclient.dylib", "steamui.dylib"] {
        let url = paths.clientDirectory.appendingPathComponent(file)
        try Data(file.utf8).write(to: url)
        hashes[file] = try SteamBuildManifest.hashFile(url)
    }
    let key = Curve25519.Signing.PrivateKey()
    let payload = SteamBuildManifest.Payload(build: "test-build", files: hashes, payloadSHA256: try SteamBuildManifest.hashFile(dylib))
    let encoded = try JSONEncoder().encode(payload)
    let envelope = SteamBuildManifest.Envelope(keyID: "fixture", payload: encoded, signature: try key.signature(for: encoded))
    let data = try JSONEncoder().encode(envelope)
    let keys = ["fixture": key.publicKey.rawRepresentation]
    let manifest = try SteamBuildManifest.verify(data, trustedKeys: keys)
    try check(manifest.validate(paths: paths, dylib: dylib), "signed matching files accepted")
    let manifestURL = root.appendingPathComponent("runtime-build.json")
    try data.write(to: manifestURL)
    let keyHex = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    func runtime(_ trustKey: String = keyHex, _ build: String = "test-build", _ capacity: Int = 1024) -> (Int32, String) {
        var diagnostic = [CChar](repeating: 42, count: max(capacity, 1))
        let status = manifestURL.path.withCString { manifestPath in paths.clientDirectory.path.withCString { client in
            dylib.path.withCString { payload in "fixture".withCString { identifier in trustKey.withCString { trust in
                build.withCString { expected in verifyRuntimeBuild(manifestPath, client, payload, identifier, trust, expected, &diagnostic, capacity) }
            } } }
        } }
        return (status, capacity > 0 ? String(decoding: diagnostic.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "")
    }
    try check(runtime().0 == 1, "native runtime entry point accepts the same installer approval")
    try check(runtime("").0 == 0, "native runtime empty compiled trust root fails closed")
    try check(runtime(String(repeating: "z", count: 64)).0 == 0, "native runtime malformed public key rejected")
    try check(runtime(keyHex, "other-build").0 == 0, "native runtime mismatched build rejected")
    try check(runtime("", "test-build", 1) == (0, ""), "native runtime terminates a one-byte diagnostic buffer")
    try check(runtime("", "test-build", 0).0 == 0, "native runtime zero diagnostic capacity")
    let payloadBytes = try Data(contentsOf: dylib)
    try Data("changed BetterSteamTools".utf8).write(to: dylib)
    try check(runtime().0 == 0, "native runtime checks its own dylib SHA-256")
    try payloadBytes.write(to: dylib)
    try rejects("unknown signing key rejected") { _ = try SteamBuildManifest.verify(data, trustedKeys: [:]) }
    let tampered = SteamBuildManifest.Envelope(keyID: "fixture", payload: encoded + Data([32]), signature: envelope.signature)
    try rejects("tampered signed payload rejected") { _ = try SteamBuildManifest.verify(JSONEncoder().encode(tampered), trustedKeys: keys) }
    try JSONEncoder().encode(tampered).write(to: manifestURL)
    try check(runtime().0 == 0, "native runtime rejects altered signed bytes")
    try data.write(to: manifestURL)
    try Data("changed Steam build".utf8).write(to: paths.clientDirectory.appendingPathComponent("steamui.dylib"))
    try check(!manifest.validate(paths: paths, dylib: dylib), "unknown Steam hash rejected")
    try check(runtime().0 == 0, "native runtime checks the full Steam file set")
}
func testCompatibilityMapping(root: URL) throws {
    let paths = SteamPaths(steamApp: root.appendingPathComponent("Steam.app"), userData: root, notProtonSupport: root.appendingPathComponent("notproton"))
    let config = root.appendingPathComponent("config/config.vdf")
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = "// keep comment\n\"InstallConfigStore\" { \"Software\" { \"Valve\" { \"Steam\" { \"CompatToolMapping\" { \"0\" { \"name\" \"global-default\" } } \"other\" \"unchanged\" } } } }"
    try original.write(to: config, atomically: true, encoding: .utf8)
    let mapping = SteamCompatibilityMapping(paths: paths, isSteamRunning: { false })
    let prefix = ["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"]
    let native = GameRouter().plan(appID: 42, override: .native, paths: paths)
    let windows = GameRouter().plan(appID: 43, override: .crossover, paths: paths)
    try mapping.apply(plan: native, toolName: nil, notProtonInstalled: true)
    var document = try KeyValuesDocument(String(contentsOf: config, encoding: .utf8))
    try check(document.entry(at: prefix + ["42", "name"])?.value == "notproton.none", "native route disables compatibility in persisted Steam mapping")
    try mapping.apply(plan: windows, toolName: "notproton-26.3", notProtonInstalled: true)
    document = try KeyValuesDocument(String(contentsOf: config, encoding: .utf8))
    try check(document.entry(at: prefix + ["43", "name"])?.value == "notproton-26.3", "Windows route stores chosen tool")
    try check(document.entry(at: prefix + ["0", "name"])?.value == "global-default", "global choice remains unchanged")
    try check(document.source.contains("// keep comment"), "config comments survive mapping")
    try mapping.apply(plan: native, toolName: nil, notProtonInstalled: false)
    document = try KeyValuesDocument(String(contentsOf: config, encoding: .utf8))
    try check(document.entry(at: prefix + ["42"]) == nil, "without NotProton remove per-app forced mapping")
    try rejects("live Steam config must not be edited") {
        try SteamCompatibilityMapping(paths: paths, isSteamRunning: { true }).apply(plan: windows, toolName: "notproton-26.3", notProtonInstalled: true)
    }
    let absent = NotProtonDiagnostics().inspect(paths: paths)
    try check(!absent.installed && !absent.readyForWindowsGames, "directories alone never imply NotProton is installed")
}
func testNotProtonLayouts(root: URL) throws {
    let fm = FileManager.default
    let fixture = root.appendingPathComponent("notproton-layouts")
    let paths = SteamPaths(steamApp: fixture.appendingPathComponent("Steam.app"), userData: fixture.appendingPathComponent("Steam"), notProtonSupport: fixture.appendingPathComponent("notproton"))
    let injected = paths.steamApp.appendingPathComponent("Contents/MacOS/notproton.dylib")
    let tool = paths.compatibilityTools.appendingPathComponent("notproton-26.3")
    let wine = paths.notProtonSupport.appendingPathComponent("runners/crossover-26.3.0.39832/CrossOver/bin/wine")
    for directory in [injected.deletingLastPathComponent(), tool, wine.deletingLastPathComponent()] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try machO(fileType: 6).write(to: injected)
    try PropertyListSerialization.data(fromPropertyList: ["LSEnvironment": ["DYLD_INSERT_LIBRARIES": injected.path]], format: .xml, options: 0).write(to: paths.infoPlist)
    try "notproton-26.3\t26.3.0.39832\trosetta\tCrossOver 26.3\n".write(to: paths.notProtonSupport.appendingPathComponent("tools"), atomically: true, encoding: .utf8)
    for executable in [tool.appendingPathComponent("run"), wine] {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    let diagnostics = NotProtonDiagnostics()
    try check(diagnostics.inspect(paths: paths).readyForWindowsGames, "current minimal NotProton layout is accepted without optional sidecars")
    let sidecar = tool.appendingPathComponent("compatibilitytool.vdf")
    try Data("compatibilitytools { broken".utf8).write(to: sidecar)
    try check(!diagnostics.inspect(paths: paths).readyForWindowsGames, "present malformed NotProton declaration must fail closed")
    try Data("compatibilitytools { compat_tools { notproton-26.3 { from_oslist windows to_oslist macos } } }".utf8).write(to: sidecar)
    try check(diagnostics.inspect(paths: paths).readyForWindowsGames, "valid optional NotProton declaration is accepted")
    try Data("compatibilitytools { compat_tools { different-tool { from_oslist windows to_oslist macos } } }".utf8).write(to: sidecar)
    try check(!diagnostics.inspect(paths: paths).readyForWindowsGames, "mismatched optional tool name is rejected")
    try fm.removeItem(at: sidecar)
    try fm.removeItem(at: wine)
    try check(!diagnostics.inspect(paths: paths).readyForWindowsGames, "missing CrossOver runner prevents readiness")
}
func testInstaller(root: URL) throws {
    let fm = FileManager.default
    let app = root.appendingPathComponent("Steam.app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let paths = SteamPaths(steamApp: app, userData: root)
    let dictionary: [String: Any] = ["LSEnvironment": ["DYLD_INSERT_LIBRARIES": "/tmp/notproton.dylib:/tmp/other.dylib:/tmp/other.dylib", "CUSTOM": "kept"], "CFBundleIdentifier": "com.valvesoftware.steam"]
    let initial = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    try initial.write(to: paths.infoPlist)
    let dylib = root.appendingPathComponent("source.dylib")
    try machO(fileType: 6).write(to: dylib)
    let backup = root.appendingPathComponent("backup/Info.plist")
    let manifest = try installerApproval(paths: paths, dylib: dylib)
    let installer = SteamBundleInstaller(paths: paths, backupURL: backup, signer: { _ in }, isSteamRunning: { false })
    try installer.install(dylib: dylib, manifest: manifest, dryRun: true)
    try check(Data(contentsOf: paths.infoPlist) == initial, "dry run leaves plist untouched")
    try check(!fm.fileExists(atPath: installer.installedDylib.path), "dry run does not copy payload")
    try installer.install(dylib: dylib, manifest: manifest)
    try installer.install(dylib: dylib, manifest: manifest)
    try check(Data(contentsOf: installer.installedBuildManifest) == manifest.envelope, "installer persists the exact signed envelope in the bundle resources")
    try check(installer.currentLibraries() == ["/tmp/notproton.dylib", "/tmp/other.dylib", installer.installedDylib.path], "idempotent installation preserves and deduplicates entries")
    try installer.uninstall()
    try check(Data(contentsOf: paths.infoPlist) == initial, "unchanged bundle restores exact original bytes")
    try installer.uninstall()
    try installer.install(dylib: dylib, manifest: manifest)
    var edited = try PropertyListSerialization.propertyList(from: Data(contentsOf: paths.infoPlist), format: nil) as! [String: Any]
    edited["new_setting"] = "later change"
    var env = edited["LSEnvironment"] as! [String: Any]
    env["DYLD_INSERT_LIBRARIES"] = (env["DYLD_INSERT_LIBRARIES"] as! String) + ":/tmp/after-install.dylib"
    edited["LSEnvironment"] = env
    try PropertyListSerialization.data(fromPropertyList: edited, format: .xml, options: 0).write(to: paths.infoPlist)
    try installer.uninstall()
    let after = try PropertyListSerialization.propertyList(from: Data(contentsOf: paths.infoPlist), format: nil) as! [String: Any]
    try check(after["new_setting"] as? String == "later change", "later plist changes survive uninstall")
    try check(installer.currentLibraries().contains("/tmp/after-install.dylib"), "later dylib insertions survive uninstall")
    let beforeFailure = try Data(contentsOf: paths.infoPlist)
    let failing = SteamBundleInstaller(paths: paths, backupURL: backup, signer: { _ in throw BundleError.signingFailed("test") }, isSteamRunning: { false })
    try rejects("signing error must not succeed") { try failing.install(dylib: dylib, manifest: manifest) }
    try check(Data(contentsOf: paths.infoPlist) == beforeFailure, "failed signing rolls plist back")
    try check(!fm.fileExists(atPath: installer.installedDylib.path), "failed signing removes owned payload")
    let running = SteamBundleInstaller(paths: paths, backupURL: backup, isSteamRunning: { true })
    try rejects("cannot change running Steam") { try running.install(dylib: dylib, manifest: manifest) }
    try Data().write(to: dylib)
    try rejects("empty dylib must not be installed") { try installer.install(dylib: dylib, manifest: manifest) }
}

func installerApproval(paths: SteamPaths, dylib: URL, key: Curve25519.Signing.PrivateKey = .init()) throws -> SteamBuildManifest {
    try FileManager.default.createDirectory(at: paths.clientDirectory, withIntermediateDirectories: true)
    var hashes: [String: String] = [:]
    for name in ["steam_osx", "steamclient.dylib", "steamui.dylib"] {
        let url = paths.clientDirectory.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        hashes[name] = try SteamBuildManifest.hashFile(url)
    }
    let payload = SteamBuildManifest.Payload(build: "fixture", files: hashes, payloadSHA256: try SteamBuildManifest.hashFile(dylib))
    let encoded = try JSONEncoder().encode(payload)
    let envelope = SteamBuildManifest.Envelope(keyID: "fixture", payload: encoded, signature: try key.signature(for: encoded))
    return try SteamBuildManifest.verify(JSONEncoder().encode(envelope), trustedKeys: ["fixture": key.publicKey.rawRepresentation])
}

if CommandLine.arguments.dropFirst().first == "--transaction-crash" {
    do { try runTransactionCrashChild(Array(CommandLine.arguments.dropFirst(2))) }
    catch { fputs("crash fixture: \(error)\n", stderr); exit(1) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("bst-selftest-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
do {
    try testKeyValues()
    try testExecutableImages(root: root)
    try testRouting(root: root)
    try testSteamAppInfo(root: root)
    try testSignedManifest(root: root)
    try testInstaller(root: root)
    try testCompatibilityMapping(root: root)
    try testNotProtonLayouts(root: root)
    try testTransactionRecovery(root: root)
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--codesign-dylib" {
        try testRealCodeSigning(root: root, dylib: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    print("PASS: KeyValues, binary classification, routing, signed runtime approval, NotProton layouts, bundle transactions and process-crash recovery")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
