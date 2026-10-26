import Foundation
import Darwin
import NativeProcessInspection

public struct InspectorListenerOwner: Sendable {
    public let pid: Int32
    public let executable: String
    public let loopbackOnly: Bool
    public init(pid: Int32, executable: String, loopbackOnly: Bool) {
        self.pid = pid; self.executable = executable; self.loopbackOnly = loopbackOnly
    }
}
public enum NativeSteamInspector {
    public static func listeners(port: UInt16) throws -> [InspectorListenerOwner] {
        var records = [LTListenerOwner](repeating: LTListenerOwner(), count: 128)
        let count = lt_tcp_listener_owners(port, &records, Int32(records.count))
        guard count >= 0 else { throw CDPError.protocolError("No se pudo obtener un inventario completo del propietario del inspector.") }
        return records.prefix(Int(count)).map { record in
            var path = record.executable
            let executable = withUnsafeBytes(of: &path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return InspectorListenerOwner(pid: record.pid, executable: executable, loopbackOnly: record.loopback_only != 0)
        }
    }
    /// A local URL or a Steam store tab alone cannot identify the native client:
    /// CrossOver's Windows Steam may expose the same inspector port and origin.
    public static func authorize(_ endpoint: URL, paths: SteamMacPaths = .detected) throws {
        guard let port = endpoint.port, let value = UInt16(exactly: port),
              CDPConnection.isLoopback(endpoint, schemes: ["http"]) else { throw CDPError.invalidEndpoint }
        let owners = try listeners(port: value)
        let roots = [paths.steamApp, paths.userData.appendingPathComponent("Steam.AppBundle/Steam")].compactMap { canonical($0.path) }
        guard !owners.isEmpty, !roots.isEmpty, owners.allSatisfy({ isNativeSteamHelper($0, approvedBundleRoots: roots) }) else {
            throw CDPError.protocolError("El puerto \(port) no pertenece exclusivamente al inspector de Steam nativo. Puede estar ocupado por Steam de Windows en CrossOver u otra aplicación.")
        }
    }
    public static func isNativeSteamHelper(_ owner: InspectorListenerOwner, approvedBundleRoots: [String]) -> Bool {
        guard owner.pid > 0, owner.loopbackOnly, !owner.executable.isEmpty,
              let path = canonical(owner.executable) else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name == "steamwebhelper" || name == "Steam Helper" else { return false }
        return approvedBundleRoots.contains { root in path.hasPrefix(root + "/Contents/") }
    }
    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
