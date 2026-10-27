import Foundation

/// Headless store-page add flow backed by the same sources and installer as
/// the desktop application. Each AppID has one cancellable operation.
public actor PluginAddCoordinator {
    public struct State: Sendable {
        public var checking = false
        public var sourcesLoaded = false
        public var sources: [LuaToolsSource] = []
        public var busy = false
        public var installing = false
        public var installStatus: String?
        public var error: String?
        public var gameName: String?
        public var activeSource: String?
        fileprivate var operation = UUID()
    }
    private let api: LuaToolsAPIClient
    private let installer: LuaInstaller
    private var states: [UInt32: State] = [:]
    private var tasks: [UInt32: Task<Void, Never>] = [:]
    public init(api: LuaToolsAPIClient, installer: LuaInstaller) { self.api = api; self.installer = installer }
    public func state(appID: UInt32) -> State? { states[appID] }
    public func start(appID: UInt32, name: String?) throws {
        guard appID > 0, name?.utf8.count ?? 0 <= 512 else { throw LuaToolsAPIError.invalidInput }
        guard states[appID]?.busy != true && states[appID]?.checking != true else { throw LuaToolsError.transactionFailed("Ya hay una operación para este juego") }
        var state = State(); state.checking = true; state.gameName = name
        let operation = state.operation; states[appID] = state
        tasks[appID] = Task { [api] in
            do { let sources = try await api.checkSources(appID: appID); try Task.checkCancellation(); self.checked(appID, operation, sources, nil) }
            catch { self.checked(appID, operation, [], error) }
        }
    }
    private func checked(_ appID: UInt32, _ operation: UUID, _ sources: [LuaToolsSource], _ error: Error?) {
        guard var state = states[appID], state.operation == operation else { return }
        state.checking = false; state.sources = sources; state.sourcesLoaded = error == nil
        state.error = error.map { ($0 is CancellationError) ? "Cancelado" : $0.localizedDescription } ?? (sources.isEmpty ? "No hay fuentes disponibles para este juego" : nil)
        states[appID] = state; tasks[appID] = nil
    }
    public func pick(appID: UInt32, source: String) throws {
        guard var state = states[appID], state.sourcesLoaded, !state.busy,
              source != "Sadie (Morrenus)", state.sources.contains(where: { $0.name == source && $0.available }) else { throw LuaToolsAPIError.invalidInput }
        let name = state.gameName
        let operation = UUID(); state.operation = operation; state.busy = true; state.activeSource = source; state.error = nil; state.installStatus = nil
        states[appID] = state
        tasks[appID] = Task { [api, installer] in
            do {
                let data = try await api.downloadManifest(appID: appID, source: source, gameName: name)
                try Task.checkCancellation()
                guard self.beginInstall(appID, operation) else { return }
                let result = try await Task.detached(priority: .utility) { try installer.installDownloaded(appID: Int(appID), data: data) }.value
                self.finished(appID, operation, "Instalado mediante \(source): \(result.manifests) manifests", nil)
            } catch { self.finished(appID, operation, nil, error) }
        }
    }
    private func beginInstall(_ appID: UInt32, _ operation: UUID) -> Bool {
        guard var state = states[appID], state.operation == operation else { return false }
        state.installing = true; states[appID] = state; return true
    }
    private func finished(_ appID: UInt32, _ operation: UUID, _ message: String?, _ error: Error?) {
        guard var state = states[appID], state.operation == operation else { return }
        state.busy = false; state.installing = false; state.activeSource = nil; state.installStatus = message
        state.error = error.map { ($0 is CancellationError) ? "Cancelado" : $0.localizedDescription }
        states[appID] = state; tasks[appID] = nil
    }
    public func cancel(appID: UInt32) throws {
        guard var state = states[appID] else { return }
        guard !state.installing else { throw LuaToolsError.transactionFailed("La instalación ya se está aplicando") }
        tasks[appID]?.cancel(); tasks[appID] = nil
        state.operation = UUID(); state.checking = false; state.busy = false; state.activeSource = nil; state.error = "Cancelado"; states[appID] = state
    }
}
