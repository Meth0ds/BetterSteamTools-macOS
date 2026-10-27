import Foundation

public enum SteamInspectorLaunchResult: Sendable, Equatable {
    case launched
    case inspectorAvailable
    case restartRequired
}

/// Launches Steam with its native Chromium debugging switch. Never silently
/// closes a running Steam or connects to a listener owned by another process.
public struct SteamInspectorLauncher: Sendable {
    public typealias RunningCheck = @Sendable () -> Bool
    public typealias ListenerCheck = @Sendable (UInt16) throws -> [InspectorListenerOwner]
    public typealias Authorize = @Sendable (URL, SteamMacPaths) throws -> Void
    public typealias Open = @Sendable (URL, [String]) throws -> Void
    private let paths: SteamMacPaths
    private let port: UInt16
    private let running: RunningCheck
    private let listeners: ListenerCheck
    private let authorize: Authorize
    private let open: Open

    public init(paths: SteamMacPaths = .detected, port: UInt16 = 8080) {
        self.init(paths: paths, port: port, running: Self.isSteamRunning,
                  listeners: { try NativeSteamInspector.listeners(port: $0) },
                  authorize: { try NativeSteamInspector.authorize($0, paths: $1) }, open: Self.openSteam)
    }
    @_spi(Testing) public init(paths: SteamMacPaths, port: UInt16, running: @escaping RunningCheck,
                               listeners: @escaping ListenerCheck, authorize: @escaping Authorize, open: @escaping Open) {
        self.paths = paths; self.port = port; self.running = running; self.listeners = listeners; self.authorize = authorize; self.open = open
    }
    public func start() throws -> SteamInspectorLaunchResult {
        guard port > 0, FileManager.default.fileExists(atPath: paths.infoPlist.path),
              let endpoint = URL(string: "http://127.0.0.1:\(port)/json") else { throw LuaToolsError.invalidRequest }
        let owners = try listeners(port)
        if running() {
            if !owners.isEmpty, (try? authorize(endpoint, paths)) != nil { return .inspectorAvailable }
            if !owners.isEmpty { throw CDPError.protocolError("El puerto \(port) está ocupado por otro proceso.") }
            return .restartRequired
        }
        guard owners.isEmpty else { throw CDPError.protocolError("El puerto \(port) está ocupado por otro proceso.") }
        try open(paths.steamApp, ["-cef-enable-debugging", "-devtools-port", String(port)])
        return .launched
    }
    private static func isSteamRunning() -> Bool {
        for name in ["steam_osx", "steam"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); process.arguments = ["-x", name]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit(); if process.terminationStatus != 1 { return true } }
            catch { return true }
        }
        return false
    }
    private static func openSteam(_ app: URL, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app.path, "--args"] + arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CDPError.protocolError("No se pudo abrir Steam con el inspector de LuaLoader.") }
    }
}
