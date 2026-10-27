import Foundation
import CryptoKit

public enum RoutingMode: String, Codable, Sendable {
    case auto
    case native
    case crossover
}

public enum GamePlatform: String, Codable, Sendable {
    case nativeMacOS = "native-macos"
    case windows
    case unknown
}

public struct SteamLibrary: Sendable, Equatable {
    public let root: URL
    public var steamapps: URL { root.appendingPathComponent("steamapps", isDirectory: true) }
    public var common: URL { steamapps.appendingPathComponent("common", isDirectory: true) }

    public init(root: URL) { self.root = root.standardizedFileURL }
}

public struct SteamPaths: Sendable {
    public let steamApp: URL
    public let userData: URL
    public let notProtonSupport: URL

    public init(steamApp: URL, userData: URL, notProtonSupport: URL? = nil) {
        self.steamApp = steamApp.standardizedFileURL
        self.userData = userData.standardizedFileURL
        self.notProtonSupport = notProtonSupport ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/notproton", isDirectory: true)
    }

    public static var detected: SteamPaths {
        let fm = FileManager.default
        let envApp = ProcessInfo.processInfo.environment["BST_STEAM_APP_PATH"].map(URL.init(fileURLWithPath:))
        let candidates = [
            envApp,
            URL(fileURLWithPath: "/Applications/Steam.app"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Steam.app")
        ].compactMap { $0 }
        let app = candidates.first(where: { fm.fileExists(atPath: $0.path) }) ?? candidates[0]
        let userData = ProcessInfo.processInfo.environment["BST_STEAM_USERDATA_PATH"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        return SteamPaths(steamApp: app, userData: userData)
    }

    public var clientDirectory: URL { userData.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS", isDirectory: true) }
    public var steamExecutable: URL { steamApp.appendingPathComponent("Contents/MacOS/steam_osx") }
    public var infoPlist: URL { steamApp.appendingPathComponent("Contents/Info.plist") }
    public var libraryFoldersVDF: URL { userData.appendingPathComponent("steamapps/libraryfolders.vdf") }
    public var compatibilityTools: URL { userData.appendingPathComponent("compatibilitytools.d") }

    public func libraries() -> [SteamLibrary] {
        var roots = [SteamLibrary(root: userData)]
        guard let text = try? String(contentsOf: libraryFoldersVDF, encoding: .utf8) else { return roots }
        guard let document = try? KeyValuesDocument(text),
              let folders = try? document.entry(at: ["libraryfolders"]) else { return roots }
        for folder in folders.children ?? [] {
            guard let raw = try? folder.string("path"), raw.hasPrefix("/") else { continue }
            let root = SteamLibrary(root: URL(fileURLWithPath: raw))
            if !roots.contains(root) { roots.append(root) }
        }
        return roots
    }
}

public struct AppManifest: Sendable, Equatable {
    public let appID: Int
    public let name: String?
    public let installDirectory: String

    public init(appID: Int, name: String?, installDirectory: String) {
        self.appID = appID
        self.name = name
        self.installDirectory = installDirectory
    }
}

public enum VDF {
    public static func value(_ key: String, in text: String) -> String? {
        guard let document = try? KeyValuesDocument(text) else { return nil }
        let root = document.entries.count == 1 && document.entries[0].children != nil
            ? document.entries[0].children! : document.entries
        let matches = root.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        return matches.count == 1 ? matches[0].value : nil
    }

    public static func appManifest(appID: Int, library: SteamLibrary) -> AppManifest? {
        guard appID > 0 else { return nil }
        let file = library.steamapps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let document = try? KeyValuesDocument(text),
              let state = try? document.entry(at: ["AppState"]),
              let id = try? state.string("appid"), Int(id) == appID,
              let installDirectory = try? state.string("installdir"),
              !installDirectory.isEmpty, ![".", ".."].contains(installDirectory),
              !installDirectory.contains("/"), !installDirectory.contains("\\"), !installDirectory.contains("\0") else { return nil }
        return AppManifest(appID: appID, name: try? state.string("name"), installDirectory: installDirectory)
    }
}

public struct InstalledGame: Sendable, Equatable {
    public let manifest: AppManifest
    public let library: SteamLibrary
    public var installURL: URL { library.common.appendingPathComponent(manifest.installDirectory, isDirectory: true) }
}

public struct GameDetector: Sendable {
    public init() {}

    public func findGame(appID: Int, paths: SteamPaths = .detected) -> InstalledGame? {
        for library in paths.libraries() {
            if let manifest = VDF.appManifest(appID: appID, library: library) {
                return InstalledGame(manifest: manifest, library: library)
            }
        }
        return nil
    }

    public func platform(of game: InstalledGame) -> GamePlatform {
        let fm = FileManager.default
        let root = game.installURL.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: root.path) else { return .unknown }
        var windows = false
        let ignored = Set(["_commonredist", "redist", "redistributables", "compatdata", "steamapps", "__macosx"])
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return .unknown }
        var scanned = 0
        for case let url as URL in enumerator {
            scanned += 1
            guard scanned <= 100_000 else { return .unknown }
            let name = url.lastPathComponent.lowercased()
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if ignored.contains(name) || values?.isSymbolicLink == true {
                enumerator.skipDescendants(); continue
            }
            if name.contains("crash") || name.contains("updater") || name.contains("uninstall") {
                enumerator.skipDescendants(); continue
            }
            if url.pathExtension.lowercased() == "app" {
                if Self.hasNativeBundleExecutable(url) { return .nativeMacOS }
                enumerator.skipDescendants(); continue
            }
            guard values?.isRegularFile == true else { continue }
            if url.pathExtension.lowercased() == "exe" {
                windows = windows || ExecutableImage.isWindowsExecutable(at: url)
            } else if fm.isExecutableFile(atPath: url.path), url.pathExtension.lowercased() != "dylib",
                      ExecutableImage.machOSlices(at: url).contains(where: \.isSupportedMacExecutable) {
                return .nativeMacOS
            }
        }
        return windows ? .windows : .unknown
    }
    private static func hasNativeBundleExecutable(_ url: URL) -> Bool {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = dict["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), !executable.contains("\\"), executable != ".." else { return false }
        return ExecutableImage.machOSlices(at: url.appendingPathComponent("Contents/MacOS/\(executable)")).contains(where: \.isSupportedMacExecutable)
    }
}

public struct RoutingOverrides: Codable, Sendable, Equatable {
    public var defaultMode: RoutingMode = .auto
    public var apps: [String: RoutingMode] = [:]
    public init(defaultMode: RoutingMode = .auto, apps: [String: RoutingMode] = [:]) { self.defaultMode = defaultMode; self.apps = apps }
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/BetterSteamTools/routing.json")
    }
    public static func load(from url: URL = Self.defaultURL) -> RoutingOverrides {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(RoutingOverrides.self, from: data) else { return .init() }
        return value
    }
    public func mode(for appID: Int) -> RoutingMode { apps[String(appID)] ?? defaultMode }
}

public struct LaunchPlan: Sendable, Equatable {
    public let appID: Int
    public let platform: GamePlatform
    public let mode: RoutingMode
    public let useNotProton: Bool
    public let explanation: String
}

public struct GameRouter: Sendable {
    private let detector = GameDetector()
    private let diagnostics = NotProtonDiagnostics()

    public init() {}

    public func plan(appID: Int, override: RoutingMode = .auto, paths: SteamPaths = .detected) -> LaunchPlan {
        let game = detector.findGame(appID: appID, paths: paths)
        let platform = game.map(detector.platform(of:)) ?? .unknown
        switch override {
        case .native:
            return LaunchPlan(appID: appID, platform: platform, mode: .native, useNotProton: false,
                              explanation: "Se ha solicitado explícitamente la ruta nativa macOS.")
        case .crossover:
            return LaunchPlan(appID: appID, platform: platform, mode: .crossover, useNotProton: true,
                              explanation: "Se ha solicitado explícitamente NotProton/CrossOver.")
        case .auto:
            if platform == .nativeMacOS {
                return LaunchPlan(appID: appID, platform: platform, mode: .native, useNotProton: false,
                                  explanation: "Se detectó un binario Mach-O o un bundle .app macOS.")
            }
            if platform == .windows {
                return LaunchPlan(appID: appID, platform: platform, mode: .crossover, useNotProton: true,
                                  explanation: "Se detectó un ejecutable Windows; NotProton/CrossOver será la ruta.")
            }
            return LaunchPlan(appID: appID, platform: .unknown, mode: .auto, useNotProton: false,
                              explanation: "No se pudo determinar la plataforma; elige --mode native o --mode crossover.")
        }
    }

    public func validate(_ plan: LaunchPlan, paths: SteamPaths = .detected) throws {
        guard plan.mode != .auto else { throw RouterError.unknownPlatform(plan.appID) }
        guard FileManager.default.fileExists(atPath: paths.steamApp.path) else { throw RouterError.steamMissing }
        if plan.useNotProton {
            let status = diagnostics.inspect(paths: paths)
            guard status.readyForWindowsGames else { throw RouterError.notProtonUnavailable(status.message) }
        }
    }

    @discardableResult
    public func launch(_ plan: LaunchPlan, paths: SteamPaths = .detected, dryRun: Bool = false) throws -> String {
        try validate(plan, paths: paths)
        let url = "steam://rungameid/\(plan.appID)"
        if !dryRun {
            let status = diagnostics.inspect(paths: paths)
            let mapping = SteamCompatibilityMapping(paths: paths)
            try mapping.apply(plan: plan, toolName: status.preferredTool?.name, notProtonInstalled: status.installed)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", "-a", paths.steamApp.path, url]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw RouterError.launchFailed }
        }
        return url
    }
}

public enum RouterError: LocalizedError, Equatable {
    case steamMissing
    case unknownPlatform(Int)
    case notProtonUnavailable(String)
    case launchFailed
    case configurationUnavailable

    public var errorDescription: String? {
        switch self {
        case .steamMissing: return "No se encontró Steam.app."
        case .unknownPlatform(let appID): return "No se pudo determinar la plataforma del AppID \(appID); usa --mode native o --mode crossover."
        case .notProtonUnavailable(let message): return message
        case .launchFailed: return "macOS no pudo abrir el juego en la copia seleccionada de Steam."
        case .configurationUnavailable: return "No se puede leer la configuración de compatibilidad de Steam."
        }
    }
}
