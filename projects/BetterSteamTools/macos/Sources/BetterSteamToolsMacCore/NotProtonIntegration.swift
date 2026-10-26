import Foundation

public struct NotProtonTool: Sendable, Equatable {
    public let name: String
    public let build: String
    public let flavor: String
    public let directory: URL
    public let runner: URL
}
public struct NotProtonStatus: Sendable {
    public let installed: Bool
    public let toolsDirectory: URL
    public let tools: [NotProtonTool]
    public let issues: [String]
    public let crossOverDetected: Bool
    public var runnerDirectories: [URL] { Array(Set(tools.map(\.runner))).sorted { $0.path < $1.path } }
    public var preferredTool: NotProtonTool? { tools.first(where: { $0.flavor == "rosetta" }) ?? tools.first }
    public var readyForWindowsGames: Bool { installed && preferredTool != nil }
    public var message: String { issues.isEmpty ? "Herramientas NotProton/CrossOver preparadas; la licencia y el juego deben validarse al ejecutar." : issues.joined(separator: "\n") }
}
public struct NotProtonDiagnostics: Sendable {
    public init() {}
    /// Builds supported by the inspected upstream b2f49e4; unknown clones are not assumed usable.
    public static let supportedBuilds: Set<String> = ["26.3.0.39832", "27.0.0.40921", "27.0.0.40921-fex", "27.0.0.41069", "27.0.0.41069-fex", "27.0.0.41073", "27.0.0.41073-fex"]
    public func inspect(paths: SteamPaths = .detected) -> NotProtonStatus {
        let fm = FileManager.default
        var issues: [String] = []
        let plist = (try? Data(contentsOf: paths.infoPlist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let environment = plist?["LSEnvironment"] as? [String: Any]
        let insert = (environment?["DYLD_INSERT_LIBRARIES"] as? String ?? "").split(separator: ":").map(String.init)
        let installed = insert.contains { path in
            URL(fileURLWithPath: path).lastPathComponent == "notproton.dylib" && ExecutableImage.machOSlices(at: URL(fileURLWithPath: path)).contains(where: \.isArm64Dylib)
        }
        if !installed { issues.append("NotProton no está desplegado en la copia de Steam seleccionada.") }
        var tools: [NotProtonTool] = []
        let list = (try? String(contentsOf: paths.notProtonSupport.appendingPathComponent("tools"), encoding: .utf8)) ?? ""
        for line in list.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { continue }
            let (name, build, flavor) = (fields[0], fields[1], fields[2])
            guard name.hasPrefix("notproton"), name.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
                  Self.supportedBuilds.contains(build), ["rosetta", "fex"].contains(flavor) else { continue }
            if flavor == "fex", ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 { continue }
            let directory = paths.compatibilityTools.appendingPathComponent(name)
            let runner = paths.notProtonSupport.appendingPathComponent("runners/crossover-\(build)/CrossOver")
            let declarationURL = directory.appendingPathComponent("compatibilitytool.vdf")
            let declared: Bool
            if fm.fileExists(atPath: declarationURL.path) {
                if let text = try? String(contentsOf: declarationURL, encoding: .utf8),
               let document = try? KeyValuesDocument(text),
               let declaration = try? document.entry(at: ["compatibilitytools", "compat_tools", name]) {
                    declared = (try? declaration.string("from_oslist")) == "windows" && (try? declaration.string("to_oslist")) == "macos"
                } else {
                    declared = false
                    issues.append("La declaración de \(name) está dañada o no coincide con la herramienta.")
                }
            } else {
                // NotProton's current macOS release intentionally ships a
                // minimal shim without Valve's optional compatibilitytool.vdf
                // or build sidecar. The local tools registry, installed dylib
                // and executable runner establish readiness in that layout;
                // the tools registry itself has no cryptographic signature.
                declared = true
            }
            guard declared,
                  fm.isExecutableFile(atPath: directory.appendingPathComponent("run").path),
                  fm.isExecutableFile(atPath: runner.appendingPathComponent("bin/wine").path) else { continue }
            tools.append(NotProtonTool(name: name, build: build, flavor: flavor, directory: directory, runner: runner))
        }
        if tools.isEmpty { issues.append("No se encontró una herramienta NotProton con registro y runner compatibles. Abre NotProton para prepararla.") }
        let crossOver = ["/Applications/CrossOver.app", "/Applications/CrossOver Preview.app", NSHomeDirectory() + "/Applications/CrossOver.app"].contains(where: { fm.fileExists(atPath: $0) })
        return NotProtonStatus(installed: installed, toolsDirectory: paths.compatibilityTools, tools: tools, issues: issues, crossOverDetected: crossOver)
    }
}

/// Steam persists this mapping under InstallConfigStore. Editing a live config is forbidden:
/// Steam could overwrite it from memory. The mapping is applied before launching the chosen app.
public struct SteamCompatibilityMapping: Sendable {
    public let paths: SteamPaths
    private let isSteamRunning: @Sendable () -> Bool
    private let prefix = ["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"]
    public init(paths: SteamPaths, isSteamRunning: @escaping @Sendable () -> Bool = SteamBundleInstaller.steamIsRunning) {
        self.paths = paths; self.isSteamRunning = isSteamRunning
    }
    public func apply(plan: LaunchPlan, toolName: String?, notProtonInstalled: Bool) throws {
        guard plan.appID > 0, plan.appID <= Int(UInt32.max), plan.mode != .auto else { throw RouterError.unknownPlatform(plan.appID) }
        guard !isSteamRunning() else { throw BundleError.steamRunning }
        let config = paths.userData.appendingPathComponent("config/config.vdf")
        guard let bytes = try? Data(contentsOf: config), let text = String(data: bytes, encoding: .utf8),
              let document = try? KeyValuesDocument(text), try document.entry(at: ["InstallConfigStore"]) != nil else { throw RouterError.configurationUnavailable }
        let app = prefix + [String(plan.appID)]
        var updated: String
        switch plan.mode {
        case .native:
            if notProtonInstalled {
                updated = try document.setting(app + ["name"], to: "notproton.none")
                updated = try KeyValuesDocument(updated).setting(app + ["priority"], to: "250")
            } else { updated = try document.removingObject(app) }
        case .crossover:
            guard let toolName, toolName.hasPrefix("notproton"), !toolName.contains("/"), !toolName.contains("\\"), notProtonInstalled else { throw RouterError.notProtonUnavailable("No hay una herramienta NotProton validada.") }
            updated = try document.setting(app + ["name"], to: toolName)
            updated = try KeyValuesDocument(updated).setting(app + ["priority"], to: "250")
        case .auto: throw RouterError.unknownPlatform(plan.appID)
        }
        let changed = Data(updated.utf8)
        if changed != bytes {
            let backup = config.appendingPathExtension("before-bst-routing")
            if !FileManager.default.fileExists(atPath: backup.path) { try bytes.write(to: backup, options: .atomic) }
            try changed.write(to: config, options: .atomic)
        }
    }
}
