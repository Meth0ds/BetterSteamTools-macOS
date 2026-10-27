import Foundation

public struct BSTNotProtonReport: Decodable, Sendable {
    public let steamApp: String
    public let installed: Bool
    public let readyForWindowsGames: Bool
    public let crossOverDetected: Bool
    public let preferredTool: String?
    public let preferredBuild: String?
    public let message: String
}

/// The app invokes the same BetterSteamTools backend used for activation and
/// compatibility decisions, avoiding a second interpretation of NotProton state.
public struct BSTHelper: Sendable {
    public let paths: SteamMacPaths
    public let executable: URL
    public init(paths: SteamMacPaths = .detected, executable: URL? = nil) {
        self.paths = paths
        self.executable = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bst-macos")
    }
    public func diagnose() throws -> BSTNotProtonReport {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw LuaToolsError.transactionFailed("La aplicación no incluye el diagnóstico de BetterSteamTools") }
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = ["doctor", "--json"]
        var environment = ProcessInfo.processInfo.environment; environment["BST_STEAM_APP_PATH"] = paths.steamApp.path
        environment["BST_STEAM_USERDATA_PATH"] = paths.userData.path
        process.environment = environment; process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 1_048_576 else {
            let message = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LuaToolsError.transactionFailed(message.isEmpty ? "Falló el diagnóstico de BetterSteamTools" : message)
        }
        do { return try JSONDecoder().decode(BSTNotProtonReport.self, from: data) }
        catch { throw LuaToolsError.transactionFailed("El diagnóstico de BetterSteamTools devolvió datos inválidos") }
    }
}
