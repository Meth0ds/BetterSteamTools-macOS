import Foundation
import CryptoKit

/// Shared lifecycle for the graphical app and the login agent. The local API
/// and the CDP dispatcher use the same router and installation state.
public actor LuaToolsBackgroundService {
    public typealias Report = @Sendable (CDPPluginStatus) async -> Void
    private let installer: LuaInstaller
    private let router: LocalAPIRouter
    private let pluginDirectory: URL?
    private let port: UInt16
    private let inspectorEndpoint: URL
    private let inspectorAuthorizer: @Sendable (URL) throws -> Void
    private var server: LocalAPIServer?
    private var injector: LuaLoaderCDPInjector?
    private var worker: Task<Void, Never>?
    private var activeDigest: Data?
    private var lastError: String?
    private var report: Report?
    private var generation: UInt64 = 0
    private var injectorRevision: UInt64 = 0
    private var refreshing = false

    public init(installer: LuaInstaller = LuaInstaller(), pluginDirectory: URL? = nil, port: UInt16 = 6767) {
        self.init(installer: installer, pluginDirectory: pluginDirectory, port: port,
                  inspectorEndpoint: URL(string: "http://127.0.0.1:8080/json")!,
                  inspectorAuthorizer: { try NativeSteamInspector.authorize($0) })
    }
    @_spi(Testing) public init(installer: LuaInstaller, pluginDirectory: URL?, port: UInt16, inspectorEndpoint: URL,
                               inspectorAuthorizer: @escaping @Sendable (URL) throws -> Void) {
        self.installer = installer
        let account = LuaToolsAuthentication()
        self.router = LocalAPIRouter(installer: installer, addCoordinator: PluginAddCoordinator(api: LuaToolsAPIClient(authentication: account), installer: installer))
        self.pluginDirectory = pluginDirectory; self.port = port; self.inspectorEndpoint = inspectorEndpoint
        self.inspectorAuthorizer = inspectorAuthorizer
    }
    @discardableResult public func start(report: @escaping Report = { _ in }) async throws -> UInt16 {
        guard server == nil, worker == nil else { throw LuaToolsError.invalidRequest }
        try installer.recoverPendingTransactions()
        let listener = try LocalAPIServer(router: router, port: port)
        let actualPort = try await listener.start()
        server = listener; self.report = report; generation &+= 1
        worker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPlugin()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        return actualPort
    }
    public func refreshPlugin() async {
        guard server != nil, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        let epoch = generation
        do {
            guard let directory = try pluginDirectory ?? PluginInstaller().resolveActiveDirectory() else {
                injectorRevision &+= 1
                if let injector { self.injector = nil; await injector.stop() }
                guard generation == epoch, server != nil else { return }
                activeDigest = nil
                if lastError != "plugin-disabled" {
                    lastError = "plugin-disabled"
                    await report?(CDPPluginStatus(cdpTabs: 0, errors: [], disabled: true))
                }
                return
            }
            let script = try PluginFrontend(pluginDirectory: directory).script
            let digest = Data(SHA256.hash(data: Data(script.utf8)))
            guard digest != activeDigest else { return }
            if let injector {
                await injector.updateFrontend(script)
                guard generation == epoch, server != nil else { return }
                activeDigest = digest; lastError = nil
                return
            }
            injectorRevision &+= 1
            let revision = injectorRevision
            if let injector { self.injector = nil; await injector.stop() }
            guard generation == epoch, server != nil else { return }
            let dispatcher = PluginRPCDispatcher(router: router)
            let transport = try LuaLoaderCDPInjector(endpoint: inspectorEndpoint, inspectorAuthorizer: inspectorAuthorizer,
                                                      handler: { method, args in try await dispatcher.call(method: method, args: args) })
            injector = transport; activeDigest = digest; lastError = nil
            await transport.start(frontend: script) { [weak self] status in await self?.forward(status, generation: epoch, revision: revision) }
        } catch {
            injectorRevision &+= 1
            if let injector { self.injector = nil; await injector.stop() }
            guard generation == epoch, server != nil else { return }
            activeDigest = nil
            let description = error.localizedDescription
            if description != lastError {
                lastError = description
                await report?(CDPPluginStatus(cdpTabs: 0, errors: [description]))
            }
        }
    }
    private func forward(_ status: CDPPluginStatus, generation epoch: UInt64, revision: UInt64) async {
        guard generation == epoch, injectorRevision == revision, server != nil else { return }
        await report?(status)
    }
    public func stop() async {
        generation &+= 1; injectorRevision &+= 1
        worker?.cancel(); worker = nil
        let oldInjector = injector; injector = nil
        let oldServer = server; server = nil; activeDigest = nil; report = nil
        if let oldInjector { await oldInjector.stop() }
        if let oldServer { await oldServer.stopAndWait() }
    }
}
