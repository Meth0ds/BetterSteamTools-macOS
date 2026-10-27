import Foundation
import LuaToolsMacCore

private actor StatusLog {
    private var previous = ""
    func write(_ status: CDPPluginStatus) {
        let message = status.disabled ? "No plugin is active" : status.errors.first ?? (status.cdpTabs == 0 ? "Waiting for native Steam" : status.pendingReloadTabs > 0 ? "Plugin update awaits page navigation" : "LuaLoader connected to \(status.cdpTabs) tab(s)")
        guard message != previous else { return }
        previous = message
        fputs("LuaToolsDaemon: \(message)\n", stderr)
    }
}

@main struct LuaToolsDaemon {
    static func main() async {
        if CommandLine.arguments == [CommandLine.arguments[0], "--check-bundle"] {
            do {
                guard let resources = Bundle.main.resourceURL else { throw LuaToolsError.invalidRequest }
                _ = try PluginFrontend(pluginDirectory: resources.appendingPathComponent("plugin-macos"))
                try PluginFrontend.validateBridgeResource()
                print("LuaToolsDaemon: bundled plugin and bridge verified")
            } catch { fputs("LuaToolsDaemon: bundle verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let service = LuaToolsBackgroundService()
        let log = StatusLog()
        do { _ = try await service.start { await log.write($0) } }
        catch { fputs("LuaToolsDaemon: \(error.localizedDescription)\n", stderr); exit(1) }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { break }
        }
        await service.stop()
    }
}
