import Foundation

public struct LuaToolsSource: Sendable, Equatable {
    public let name: String
    public let status: String
    public var available: Bool { status == "available" }
}
public enum LuaToolsAPIError: LocalizedError {
    case invalidInput, invalidResponse, rejected(Int), tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "La solicitud a LuaTools no es válida."
        case .invalidResponse: "El servidor de LuaTools devolvió una respuesta no válida."
        case .rejected(let code): "El servidor de LuaTools rechazó la solicitud (HTTP \(code))."
        case .tooLarge: "La descarga supera el tamaño permitido."
        }
    }
}

/// The endpoint and payloads follow the original Windows LuaToolsApiClient.
/// The bearer token is only attached to the HTTPS lua.tools endpoint.
public struct LuaToolsAPIClient: Sendable {
    @_spi(Testing) public typealias Transport = @Sendable (URLRequest, Int) async throws -> (Data, Int)
    private let token: @Sendable () async throws -> String
    private let transport: Transport
    public init(authentication: LuaToolsAuthentication) {
        token = { try await authentication.accessToken() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: LuaToolsAPIRedirectPolicy(), delegateQueue: nil)
        transport = { request, maximum in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw LuaToolsAPIError.invalidResponse }
            if !(200..<300).contains(http.statusCode) { return (Data(), http.statusCode) }
            guard http.expectedContentLength <= maximum else { throw LuaToolsAPIError.tooLarge }
            var data = Data()
            var chunk: [UInt8] = []; chunk.reserveCapacity(65_536)
            for try await byte in bytes {
                guard data.count + chunk.count < maximum else { throw LuaToolsAPIError.tooLarge }
                chunk.append(byte)
                if chunk.count == 65_536 { data.append(contentsOf: chunk); chunk.removeAll(keepingCapacity: true) }
            }
            data.append(contentsOf: chunk)
            return (data, http.statusCode)
        }
    }
    @_spi(Testing) public init(token: @escaping @Sendable () async throws -> String, transport: @escaping Transport) {
        self.token = token; self.transport = transport
    }
    public func checkSources(appID: UInt32) async throws -> [LuaToolsSource] {
        guard appID > 0 else { throw LuaToolsAPIError.invalidInput }
        var components = URLComponents(string: "http://167.235.229.108/check_apis")!
        components.queryItems = [URLQueryItem(name: "appid", value: String(appID))]
        var request = URLRequest(url: components.url!); request.setValue("secretgoonpoon", forHTTPHeaderField: "User-Agent")
        let bytes = try await checked(request, limit: 1_048_576)
        guard let map = try? JSONDecoder().decode([String: String].self, from: bytes), map.count <= 128,
              map.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.utf8.count <= 128 }) else { throw LuaToolsAPIError.invalidResponse }
        return map.map { LuaToolsSource(name: $0.key, status: $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    public func downloadManifest(appID: UInt32, source: String, gameName: String? = nil) async throws -> Data {
        guard appID > 0, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.utf8.count <= 256,
              gameName?.utf8.count ?? 0 <= 512 else { throw LuaToolsAPIError.invalidInput }
        var components = URLComponents(string: "https://lua.tools/api/manifest/download")!
        components.queryItems = [URLQueryItem(name: "appid", value: String(appID)), URLQueryItem(name: "source", value: source)]
        if let gameName, !gameName.isEmpty { components.queryItems?.append(URLQueryItem(name: "game_name", value: gameName)) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let data = try await checked(request, limit: 256 * 1024 * 1024)
        guard !data.isEmpty else { throw LuaToolsAPIError.invalidResponse }
        return data
    }
    private func checked(_ request: URLRequest, limit: Int) async throws -> Data {
        let (data, status) = try await transport(request, limit)
        guard (200..<300).contains(status) else { throw LuaToolsAPIError.rejected(status) }
        guard data.count <= limit else { throw LuaToolsAPIError.tooLarge }
        return data
    }
}

private final class LuaToolsAPIRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
