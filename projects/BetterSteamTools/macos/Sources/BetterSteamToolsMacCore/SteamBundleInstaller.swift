import Foundation
import CryptoKit

public enum BundleError: Error, LocalizedError, Equatable {
    case steamMissing, dylibMissing, invalidManifest, invalidDylib, invalidPlist
    case steamRunning, foreignPayload, invalidReceipt, payloadChanged, recoveryConflict
    case signingFailed(String), rollbackFailed(String)
    public var errorDescription: String? {
        switch self {
        case .steamMissing: "Steam.app o Info.plist no está disponible."
        case .dylibMissing: "No se encontró la dylib de BetterSteamTools."
        case .invalidManifest: "La build de Steam no tiene un manifiesto válido y verificado."
        case .invalidDylib: "El archivo no es una dylib Mach-O arm64 válida."
        case .invalidPlist: "Info.plist no contiene un diccionario de propiedades válido."
        case .steamRunning: "Cierra Steam antes de modificar su instalación."
        case .foreignPayload: "Ya existe una dylib sin registro de propiedad; no se sobrescribirá."
        case .invalidReceipt: "El registro de instalación no corresponde a esta copia de Steam."
        case .payloadChanged: "La dylib o su manifiesto cambió fuera del instalador; no se eliminará."
        case .recoveryConflict: "La copia de Steam cambió durante la operación; no se sobrescribirá."
        case .signingFailed(let message): "No se pudo firmar Steam: \(message)"
        case .rollbackFailed(let message): "La restauración necesita atención: \(message)"
        }
    }
}

/// Activation is staged beside Steam and committed by an atomic bundle swap.
/// The original executable, signature resources, ACLs and xattrs are retained.
public struct SteamBundleInstaller: Sendable {
    public typealias Signer = @Sendable (URL) throws -> Void
    public enum Checkpoint: String, Sendable { case staging, prepared, swapped, receiptPersisted, committed }
    public typealias Observer = @Sendable (Checkpoint) throws -> Void
    public let paths: SteamPaths
    public let backupURL: URL
    private let signer: Signer
    private let isSteamRunning: @Sendable () -> Bool
    private let observer: Observer
    public var installedDylib: URL { paths.steamApp.appendingPathComponent("Contents/MacOS/BetterSteamTools.dylib") }
    public var installedBuildManifest: URL { paths.steamApp.appendingPathComponent("Contents/Resources/BetterSteamTools.build.json") }
    public init(paths: SteamPaths = .detected, backupURL: URL? = nil,
                signer: @escaping Signer = SteamBundleInstaller.adHocSign,
                isSteamRunning: @escaping @Sendable () -> Bool = SteamBundleInstaller.steamIsRunning,
                observer: @escaping Observer = { _ in }) {
        self.paths = paths
        let identifier = BundleFileSystem.hash(Data(paths.steamApp.resolvingSymlinksInPath().path.utf8))
        self.backupURL = backupURL ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/BetterSteamTools/backups/\(identifier)/Info.plist")
        self.signer = signer; self.isSteamRunning = isSteamRunning; self.observer = observer
    }
    private var transaction: SteamBundleTransaction {
        SteamBundleTransaction(paths: paths, stateDirectory: backupURL.deletingLastPathComponent(),
                               signer: signer, isSteamRunning: isSteamRunning, observer: observer)
    }
    public func currentLibraries() throws -> [String] {
        try SteamBundleTransaction.libraries(in: Data(contentsOf: paths.infoPlist))
    }
    public func install(dylib: URL, manifest: SteamBuildManifest, dryRun: Bool = false) throws {
        try transaction.install(dylib: dylib, manifest: manifest, dryRun: dryRun)
    }
    public func uninstall(dryRun: Bool = false) throws { try transaction.uninstall(dryRun: dryRun) }
    public func recover() throws { try transaction.recover() }
    public static func steamIsRunning() -> Bool {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); process.arguments = ["-x", "steam_osx"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus != 1 }
        catch { return true }
    }
    public static func adHocSign(_ app: URL) throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("bst-sign-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close(); try? FileManager.default.removeItem(at: log) }
        for arguments in [["--force", "--sign", "-", app.path], ["--verify", "--strict", app.path]] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); process.arguments = arguments
            process.standardOutput = output; process.standardError = output
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw BundleError.signingFailed((try? String(contentsOf: log, encoding: .utf8)) ?? "codesign exit \(process.terminationStatus)")
            }
        }
    }
}
