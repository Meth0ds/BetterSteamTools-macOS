import Foundation
import LuaToolsMacCore

func testBSTHelper(root: URL) throws {
    let helper = root.appendingPathComponent("fake bst helper")
    let shell = #"""
    #!/bin/sh
    [ "$1" = doctor ] && [ "$2" = --json ] || exit 2
    case "$BST_STEAM_APP_PATH" in */Steam.app) ;; *) exit 3 ;; esac
    case "$BST_STEAM_USERDATA_PATH" in */SteamData) ;; *) exit 4 ;; esac
    printf '%s\n' '{"steamApp":"fixture","installed":true,"readyForWindowsGames":true,"crossOverDetected":true,"preferredTool":"notproton-test","preferredBuild":"26.3","message":"ready"}'
    """#
    try shell.write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let paths = SteamMacPaths(steamApp: root.appendingPathComponent("Steam.app"), userData: root.appendingPathComponent("SteamData"))
    let result = try BSTHelper(paths: paths, executable: helper).diagnose()
    try check(result.installed && result.readyForWindowsGames && result.preferredTool == "notproton-test", "GUI diagnostic uses the bundled BetterSteamTools protocol")
    let installer = #"""
    #!/bin/sh
    [ "$1" = install ] && [ "$2" = --dylib ] && [ "$4" = --manifest ] && [ "$6" = --dry-run ] || exit 2
    case "$BST_STEAM_APP_PATH" in */Steam.app) ;; *) exit 3 ;; esac
    case "$BST_STEAM_USERDATA_PATH" in */SteamData) ;; *) exit 4 ;; esac
    case "$3" in *"with spaces.dylib") ;; *) exit 5 ;; esac
    case "$5" in *"signed manifest.json") ;; *) exit 6 ;; esac
    """#
    try installer.write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    try SteamActivation(paths: paths, helper: helper).activate(dylib: root.appendingPathComponent("with spaces.dylib"), manifest: root.appendingPathComponent("signed manifest.json"), dryRun: true)
    try "#!/bin/sh\nprintf 'failure message' >&2\nexit 1\n".write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    do { _ = try BSTHelper(paths: paths, executable: helper).diagnose(); throw TestFailure(description: "failed BST diagnostic accepted") } catch is LuaToolsError { }
}
