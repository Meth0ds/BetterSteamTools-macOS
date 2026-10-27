import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LuaToolsMacCore

@main
struct LuaToolsMacApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("LuaTools") { ContentView(model: model).frame(minWidth: 620, minHeight: 420) }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var status = "Preparado"
    @Published var appID = ""
    @Published var pluginStatus = "Plugin pendiente de instalación"
    @Published var selected: LuaToolsSection = .overview
    private let paths = SteamMacPaths.detected
    private let installer = LuaInstaller()
    private var service: LuaToolsBackgroundService?
    init() {
        Task { await startLocalService() }
    }
    private func startLocalService() async {
        if await LuaToolsServiceDiscovery.isRunning() {
            status = "Servicio de LuaTools activo en segundo plano"
            pluginStatus = "El servicio está sincronizando LuaLoader con Steam"
            return
        }
        let local = LuaToolsBackgroundService(installer: installer)
        do {
            _ = try await local.start { [weak self] report in await self?.showPluginStatus(report) }
            service = local
        } catch {
            if await LuaToolsServiceDiscovery.isRunning() {
                status = "Servicio de LuaTools activo en segundo plano"
                pluginStatus = "El servicio está sincronizando LuaLoader con Steam"
            } else { status = "No se pudo iniciar el servicio local: \(error.localizedDescription)" }
        }
    }
    func refresh() {
        let steam = FileManager.default.fileExists(atPath: paths.infoPlist.path) ? "Steam detectado" : "Steam no encontrado"
        status = "\(steam) · Lua: \(paths.stPlugin.path)"
    }
    func installLua() {
        guard let id = Int(appID) else { status = "AppID no válido"; return }
        status = installer.hasLua(appID: id) ? "Lua ya instalado para \(id)" : "Indica un archivo Lua desde la API local (6767)"
    }
    func installLuaFromPanel() {
        guard let id = Int(appID), id > 0 else { status = "Introduce un AppID válido"; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "lua")!]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do { let result = try installer.installLua(appID: id, source: source); status = "Lua instalado en \(result.luaURL.path)" }
        catch { status = "No se pudo instalar el Lua: \(error.localizedDescription)" }
    }
    func installPackage() {
        guard let id = Int(appID), id > 0 else { status = "Introduce un AppID válido"; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "zip")!]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do { let result = try installer.installZip(appID: id, zip: source); status = "Paquete instalado: \(result.manifests) manifest(s)" }
        catch { status = "No se pudo instalar el paquete: \(error.localizedDescription)" }
    }
    func activateBST() {
        guard let raw = ProcessInfo.processInfo.environment["BETTERSTEAMTOOLS_MAC_DYLIB"],
              let manifest = ProcessInfo.processInfo.environment["BETTERSTEAMTOOLS_MAC_MANIFEST"] else { status = "Selecciona una dylib y su manifiesto firmado para activar BetterSteamTools"; return }
        do { try SteamActivation().activate(dylib: URL(fileURLWithPath: raw), manifest: URL(fileURLWithPath: manifest)); status = "BetterSteamTools añadido sin sustituir NotProton" }
        catch { status = "No se pudo activar BetterSteamTools: \(error.localizedDescription)" }
    }
    func installAgent() {
        Task {
            let daemon = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LuaToolsDaemon")
            guard FileManager.default.isExecutableFile(atPath: daemon.path) else { status = "La aplicación no incluye LuaToolsDaemon"; return }
            if let service { await service.stop(); self.service = nil }
            do { let url = try LaunchAgentInstaller().install(executable: daemon); status = "LaunchAgent instalado en \(url.path)" }
            catch {
                let message = error.localizedDescription
                await startLocalService()
                status = "No se pudo instalar el LaunchAgent: \(message)"
            }
        }
    }
    func injectCDP() { Task { await connectPlugin() } }
    func launchSteamForPlugin() {
        do {
            switch try SteamInspectorLauncher(paths: paths).start() {
            case .launched: status = "Steam iniciado con el inspector de LuaLoader"
            case .inspectorAvailable: status = "El inspector de Steam ya está disponible"; injectCDP()
            case .restartRequired: status = "Cierra Steam y usa esta acción para abrirlo con LuaLoader"
            }
        } catch { status = "No se pudo preparar LuaLoader: \(error.localizedDescription)" }
    }
    private func connectPlugin() async {
        if let service { await service.refreshPlugin() }
        else if await LuaToolsServiceDiscovery.isRunning() { pluginStatus = "El servicio en segundo plano está sincronizando LuaLoader" }
        else { pluginStatus = "El servicio de LuaTools no está disponible" }
    }
    private func showPluginStatus(_ report: CDPPluginStatus) {
        if let error = report.errors.first { pluginStatus = "Esperando al inspector de Steam: \(error)" }
        else if report.cdpTabs == 0 { pluginStatus = "Esperando a la tienda de Steam" }
        else if report.pendingReloadTabs > 0 { pluginStatus = "Actualización lista; recarga la tienda para aplicarla" }
        else { pluginStatus = "LuaLoader · Plugin conectado en \(report.cdpTabs) pestaña(s)" }
    }
    func installPlugin() {
        guard let raw = ProcessInfo.processInfo.environment["LUA_TOOLS_MAC_PLUGIN_ZIP"] else { status = "Define LUA_TOOLS_MAC_PLUGIN_ZIP con plugin-macos.zip"; return }
        do { try PluginInstaller().install(zip: URL(fileURLWithPath: raw)); status = "Plugin LuaTools instalado"; Task { await connectPlugin() } }
        catch { status = "No se pudo instalar el plugin: \(error.localizedDescription)" }
    }
}

enum LuaToolsSection: String, CaseIterable, Identifiable {
    case overview = "Resumen", games = "Juegos", lua = "Lua y depots", operations = "Operaciones", settings = "Ajustes"
    var id: Self { self }
    var symbol: String { switch self { case .overview: "rectangle.grid.2x2"; case .games: "gamecontroller"; case .lua: "doc.text"; case .operations: "arrow.triangle.2.circlepath"; case .settings: "gearshape" } }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            List(LuaToolsSection.allCases, selection: $model.selected) { item in Label(item.rawValue, systemImage: item.symbol).tag(item) }
                .navigationTitle("LuaTools")
                .safeAreaInset(edge: .bottom) { VStack(alignment: .leading) { Text(model.status).font(.caption); Text(model.pluginStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }.padding(12) }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text(model.selected.rawValue).font(.title.bold()); Spacer(); Button("Actualizar", action: model.refresh) }.padding(22)
                Divider()
                ScrollView { detail.padding(28) }
            }
        }
    }
    @ViewBuilder private var detail: some View {
        switch model.selected {
        case .overview:
            VStack(alignment: .leading, spacing: 22) {
                Text("Gestiona Steam desde macOS").font(.largeTitle.bold())
                Text("LuaTools conserva el flujo de Windows y usa NotProton solo cuando un juego necesita CrossOver.").foregroundStyle(.secondary)
                HStack { statusCard("Steam", "steam", FileManager.default.fileExists(atPath: SteamMacPaths.detected.infoPlist.path) ? "Detectado" : "No encontrado"); statusCard("Plugin", "puzzlepiece.extension", model.pluginStatus) }
                GroupBox("Acciones rápidas") { HStack { Button("Activar BetterSteamTools", action: model.activateBST); Button("Abrir Steam para LuaLoader", action: model.launchSteamForPlugin); Button("Conectar plugin", action: model.injectCDP); Button("LaunchAgent", action: model.installAgent); Spacer() }.padding(8) }
                Text(model.status).foregroundStyle(.secondary)
            }
        case .games:
            VStack(alignment: .leading, spacing: 18) { Text("Juegos añadidos").font(.title2.bold()); Text("La biblioteca mostrará el modo automático: nativo macOS, NotProton/CrossOver o selección manual.").foregroundStyle(.secondary); ContentUnavailableView("Esperando sincronización con Steam", systemImage: "gamecontroller", description: Text("Abre Steam y conecta el plugin para cargar los juegos.")) }
        case .lua:
            VStack(alignment: .leading, spacing: 16) { Text("Lua y depots").font(.title2.bold()); Text("Los Lua se guardan en stplug-in y los manifests binarios en depotcache, sin cambiar el formato de Windows.").foregroundStyle(.secondary); HStack { TextField("AppID", text: $model.appID).textFieldStyle(.roundedBorder).frame(width: 170); Button("Comprobar", action: model.installLua); Button("Instalar Lua", action: model.installLuaFromPanel); Button("Instalar ZIP", action: model.installPackage) }; GroupBox("Rutas") { VStack(alignment: .leading) { Text(SteamMacPaths.detected.stPlugin.path); Text(SteamMacPaths.detected.depotCache.path) }.font(.caption.monospaced()).padding(8) } }
        case .operations:
            VStack(alignment: .leading, spacing: 16) { Text("Operaciones").font(.title2.bold()); GroupBox("Servicios") { VStack(alignment: .leading) { Button("Instalar LaunchAgent", action: model.installAgent); Text("API local: 127.0.0.1:6767").foregroundStyle(.secondary) }.padding(8) }; Text(model.pluginStatus).foregroundStyle(.secondary) }
        case .settings:
            Form { Section("Compatibilidad") { Text("El plugin utiliza LuaLoader y el servicio local de LuaTools."); Text("NotProton no descarga CrossOver ni modifica licencias.").foregroundStyle(.secondary) } }.formStyle(.grouped)
        }
    }
    private func statusCard(_ title: String, _ symbol: String, _ value: String) -> some View { VStack(alignment: .leading) { Label(title, systemImage: symbol).font(.headline); Text(value).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10)) }
}
