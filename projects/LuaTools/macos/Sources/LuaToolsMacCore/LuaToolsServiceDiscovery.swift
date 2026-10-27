import Foundation
import Darwin

private final class NoServiceRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum LuaToolsServiceDiscovery {
    public static func isTrustedOwner(_ owner: InspectorListenerOwner, appBundle: URL) -> Bool {
        guard owner.pid > 0, owner.loopbackOnly, appBundle.pathExtension.lowercased() == "app",
              let root = canonical(appBundle.path), let executable = canonical(owner.executable) else { return false }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return ["LuaToolsDaemon", "LuaToolsMac"].contains(name) && executable == root + "/Contents/MacOS/" + name
    }
    public static func isRunning(appBundle: URL = Bundle.main.bundleURL, port: UInt16 = 6767) async -> Bool {
        guard port > 0, let endpoint = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        func authorized() -> Bool {
            guard let owners = try? NativeSteamInspector.listeners(port: port), !owners.isEmpty else { return false }
            return owners.allSatisfy { isTrustedOwner($0, appBundle: appBundle) }
        }
        guard authorized() else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config, delegate: NoServiceRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: endpoint), data.count <= 65_536,
              (response as? HTTPURLResponse)?.statusCode == 200, response.url == endpoint,
              let json = try? JSONDecoder().decode(BridgeJSON.self, from: data), json["service"]?.string == "luatools",
              json["apiVersion"]?.integer == 1, authorized() else { return false }
        return true
    }
    private static func canonical(_ path: String) -> String? {
        guard !path.isEmpty, let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }; return String(cString: resolved)
    }
}
