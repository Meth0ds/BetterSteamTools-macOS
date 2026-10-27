import Foundation
import BetterSteamToolsMacCore

@main
struct BSTMacCLI {
    static func main() {
        do { try run(Array(CommandLine.arguments.dropFirst())) }
        catch { fputs("bst-macos: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    private static func run(_ args: [String]) throws {
        guard let command = args.first else { return usage() }
        let paths = SteamPaths.detected
        switch command {
        case "doctor":
            let status = NotProtonDiagnostics().inspect(paths: paths)
            if args.contains("--json") {
                struct DoctorResult: Encodable {
                    let steamApp: String; let installed: Bool; let readyForWindowsGames: Bool; let crossOverDetected: Bool
                    let preferredTool: String?; let preferredBuild: String?; let message: String
                }
                let report = DoctorResult(steamApp: paths.steamApp.path, installed: status.installed,
                    readyForWindowsGames: status.readyForWindowsGames, crossOverDetected: status.crossOverDetected,
                    preferredTool: status.preferredTool?.name, preferredBuild: status.preferredTool?.build, message: status.message)
                let data = try JSONEncoder().encode(report)
                guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
                print(text); return
            }
            print("Steam: \(paths.steamApp.path)")
            print("NotProton: \(status.message)")
            print("Runners: \(status.runnerDirectories.map(\.lastPathComponent).joined(separator: ", "))")
        case "appinfo":
            guard let raw = args.dropFirst().first, let appID = UInt32(raw), appID > 0 else { throw RouterError.unknownPlatform(0) }
            let file = paths.userData.appendingPathComponent("appcache/appinfo.vdf")
            if let metadata = try SteamAppInfoReader(url: file).read(appID: appID) {
                let mac64 = metadata.supportsMacOS64Bit.map { $0 ? "yes" : "no" } ?? "unknown"
                print("appid=\(appID) name=\(metadata.name ?? "") platforms=\(metadata.platforms.sorted().joined(separator: ",")) mac64=\(mac64)")
            } else { print("appid=\(appID) no metadata cached") }
        case "validate-build":
            guard let manifestPath = parseValue(args, key: "--manifest") else { throw BundleError.invalidManifest }
            let manifest = try SteamBuildManifest.load(from: URL(fileURLWithPath: manifestPath))
            guard manifest.validate(paths: paths) else { throw BundleError.invalidManifest }
            print("Steam build \(manifest.approved.build) validada.")
        case "plan":
            guard let appID = Int(args.dropFirst().first ?? "") else { throw RouterError.unknownPlatform(0) }
            let mode = parseMode(args) ?? RoutingOverrides.load().mode(for: appID)
            let plan = GameRouter().plan(appID: appID, override: mode, paths: paths)
            print("appid=\(appID) platform=\(plan.platform.rawValue) mode=\(plan.mode.rawValue) notproton=\(plan.useNotProton)")
            print(plan.explanation)
        case "launch":
            guard let appID = Int(args.dropFirst().first ?? "") else { throw RouterError.unknownPlatform(0) }
            let mode = parseMode(args) ?? RoutingOverrides.load().mode(for: appID)
            let plan = GameRouter().plan(appID: appID, override: mode, paths: paths)
            let url = try GameRouter().launch(plan, paths: paths, dryRun: args.contains("--dry-run"))
            print(url)
        case "install":
            guard let payload = parseValue(args, key: "--dylib"), let manifestPath = parseValue(args, key: "--manifest") else { throw BundleError.invalidManifest }
            let dylib = URL(fileURLWithPath: payload)
            let manifest = try SteamBuildManifest.load(from: URL(fileURLWithPath: manifestPath))
            guard manifest.validate(paths: paths, dylib: dylib) else { throw BundleError.invalidManifest }
            try SteamBundleInstaller(paths: paths).install(dylib: dylib, manifest: manifest, dryRun: args.contains("--dry-run"))
            print(args.contains("--dry-run") ? "Instalación validada sin cambios." : "BetterSteamTools y su manifiesto firmado instalados.")
        case "uninstall":
            try SteamBundleInstaller(paths: paths).uninstall(dryRun: args.contains("--dry-run"))
            print(args.contains("--dry-run") ? "Desinstalación validada sin cambios." : "Integración macOS restaurada.")
        case "recover":
            try SteamBundleInstaller(paths: paths).recover()
            print("Recuperación de transacciones completada.")
        default: usage()
        }
    }

    private static func parseMode(_ args: [String]) -> RoutingMode? {
        guard let value = parseValue(args, key: "--mode") else { return nil }
        return RoutingMode(rawValue: value)
    }
    private static func parseValue(_ args: [String], key: String) -> String? {
        guard let index = args.firstIndex(of: key), args.index(after: index) < args.endIndex else { return nil }
        return args[args.index(after: index)]
    }
    private static func usage() {
        print("Uso: bst-macos doctor | appinfo <appid> | validate-build --manifest <path> | plan <appid> [--mode auto|native|crossover] | launch <appid> [--mode ...] [--dry-run] | install --dylib <path> --manifest <signed.json> | uninstall | recover")
    }
}
