import Foundation
import Darwin

public struct LaunchAgentInstaller: Sendable {
    public typealias Runner = @Sendable ([String]) throws -> Int32
    private static let label = "com.luatools.macos"
    private let directory: URL
    private let uid: UInt32
    private let runner: Runner

    public init() {
        self.init(directory: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents"), uid: getuid(), runner: Self.launchctl)
    }
    @_spi(Testing) public init(directory: URL, uid: UInt32, runner: @escaping Runner) {
        self.directory = directory; self.uid = uid; self.runner = runner
    }
    public func install(executable: URL) throws -> URL {
        guard executable.lastPathComponent == "LuaToolsDaemon", FileManager.default.isExecutableFile(atPath: executable.path),
              try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try executable.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LuaToolsError.invalidRequest }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(Self.label + ".plist")
        let previous = try existingOwnedFile(file)
        let target = "gui/\(uid)/\(Self.label)", domain = "gui/\(uid)"
        let wasLoaded = try runner(["print", target]) == 0
        if wasLoaded, try runner(["bootout", target]) != 0 { throw LuaToolsError.transactionFailed("No se pudo detener el LaunchAgent anterior") }
        let dictionary: [String: Any] = ["Label": Self.label, "ProgramArguments": [executable.path], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10, "ProcessType": "Background"]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            try data.write(to: file, options: .atomic)
            guard try runner(["bootstrap", domain, file.path]) == 0 else { throw LuaToolsError.transactionFailed("launchctl no pudo iniciar el LaunchAgent") }
            return file
        } catch {
            do {
                if let previous { try previous.write(to: file, options: .atomic) }
                else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                if wasLoaded, previous != nil, try runner(["bootstrap", domain, file.path]) != 0 { throw LuaToolsError.transactionFailed("No se pudo restaurar el LaunchAgent anterior") }
            } catch { throw LuaToolsError.transactionFailed("No se pudo restaurar el LaunchAgent anterior: \(error.localizedDescription)") }
            throw error
        }
    }
    public func uninstall() throws {
        let file = directory.appendingPathComponent(Self.label + ".plist")
        guard try existingOwnedFile(file) != nil else { return }
        let target = "gui/\(uid)/\(Self.label)"
        if try runner(["print", target]) == 0, try runner(["bootout", target]) != 0 { throw LuaToolsError.transactionFailed("No se pudo detener el LaunchAgent") }
        try FileManager.default.removeItem(at: file)
    }
    private func existingOwnedFile(_ url: URL) throws -> Data? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw LuaToolsError.transactionFailed("No se pudo consultar el LaunchAgent")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size >= 0, info.st_size <= 65_536 else { throw LuaToolsError.transactionFailed("El LaunchAgent existente no es un archivo propio") }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw LuaToolsError.transactionFailed("No se pudo abrir el LaunchAgent existente") }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size >= 0, info.st_size <= 65_536 else { throw LuaToolsError.transactionFailed("El LaunchAgent existente no es un archivo propio") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw LuaToolsError.transactionFailed("El LaunchAgent existente es demasiado grande") }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == Self.label, let args = plist["ProgramArguments"] as? [String], args.count == 1,
              URL(fileURLWithPath: args[0]).lastPathComponent == "LuaToolsDaemon" else { throw LuaToolsError.transactionFailed("El LaunchAgent existente no pertenece a LuaTools") }
        return data
    }
    private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    }
}
