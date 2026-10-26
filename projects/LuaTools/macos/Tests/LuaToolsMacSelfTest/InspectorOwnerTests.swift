import Foundation
import Darwin
import LuaToolsMacCore

func testInspectorOwnerPaths(root: URL) throws {
    let bundle = root.appendingPathComponent("InspectorSteam.app")
    let helper = bundle.appendingPathComponent("Contents/Frameworks/Steam Helper.app/Contents/MacOS/Steam Helper")
    try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: helper)
    guard let resolved = realpath(bundle.path, nil) else { throw TestFailure(description: "fixture path") }
    defer { free(resolved) }
    let roots = [String(cString: resolved)]
    let valid = InspectorListenerOwner(pid: getpid(), executable: helper.path, loopbackOnly: true)
    try check(NativeSteamInspector.isNativeSteamHelper(valid, approvedBundleRoots: roots), "native helper under the selected app is recognized")
    try check(!NativeSteamInspector.isNativeSteamHelper(.init(pid: getpid(), executable: helper.path, loopbackOnly: false), approvedBundleRoots: roots), "public/wildcard inspector listener rejected")
    let wine = root.appendingPathComponent("CrossOver/wine64-preloader")
    try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: wine)
    try check(!NativeSteamInspector.isNativeSteamHelper(.init(pid: getpid(), executable: wine.path, loopbackOnly: true), approvedBundleRoots: roots), "Wine owner cannot impersonate native Steam")
    let foreign = root.appendingPathComponent("OtherSteam.app/Contents/MacOS/Steam Helper")
    try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: foreign)
    try check(!NativeSteamInspector.isNativeSteamHelper(.init(pid: getpid(), executable: foreign.path, loopbackOnly: true), approvedBundleRoots: roots), "helper in another installation rejected")
    let link = bundle.appendingPathComponent("Contents/MacOS/steamwebhelper")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
    try check(!NativeSteamInspector.isNativeSteamHelper(.init(pid: getpid(), executable: link.path, loopbackOnly: true), approvedBundleRoots: roots), "helper symlink escaping the approved app rejected")
}

func testLiveListenerOwnership(port: UInt16) throws {
    let owners = try NativeSteamInspector.listeners(port: port)
    try check(owners.contains(where: { $0.pid == getpid() && $0.loopbackOnly && !$0.executable.isEmpty }), "libproc identifies this real loopback TCP listener and executable")
    let endpoint = URL(string: "http://127.0.0.1:\(port)/json")!
    do { try NativeSteamInspector.authorize(endpoint) }
    catch { return }
    throw TestFailure(description: "A test process must never be authorized as native Steam")
}
