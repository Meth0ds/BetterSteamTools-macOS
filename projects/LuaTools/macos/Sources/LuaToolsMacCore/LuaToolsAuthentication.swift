import Foundation
import Security

public enum LuaToolsAuthenticationError: LocalizedError {
    case invalidCode, signedOut, invalidResponse, rejected(Int), credentialStore(OSStatus), sessionChanged
    public var errorDescription: String? {
        switch self {
        case .invalidCode: "Introduce un código de Discord válido."
        case .signedOut: "Inicia sesión en LuaTools para continuar."
        case .invalidResponse: "La respuesta de autenticación no es válida."
        case .rejected(let status): "El servidor rechazó la autenticación (HTTP \(status))."
        case .credentialStore(let status): "No se pudo acceder al llavero de LuaTools (\(status))."
        case .sessionChanged: "La sesión cambió durante la autenticación."
        }
    }
}

public struct LuaToolsAccount: Sendable, Equatable {
    public let email: String?
    public let displayName: String?
}

@_spi(Testing) public protocol LuaToolsCredentialStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

private struct KeychainCredentialStore: LuaToolsCredentialStore {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.luatools.macos.account", kSecAttrAccount as String: "session"] }
    func read() throws -> Data? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LuaToolsAuthenticationError.credentialStore(status) }
        guard let data = result as? Data else { throw LuaToolsAuthenticationError.invalidResponse }
        return data
    }
    func write(_ data: Data) throws {
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw LuaToolsAuthenticationError.credentialStore(added) }
        } else if status != errSecSuccess { throw LuaToolsAuthenticationError.credentialStore(status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LuaToolsAuthenticationError.credentialStore(status) }
    }
}

/// Discord bot-code and refresh flows from the Windows client. Credentials are
/// kept in Keychain, never in defaults, HTTP logs or the plugin's RPC surface.
public actor LuaToolsAuthentication {
    @_spi(Testing) public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private struct Stored: Codable, Sendable {
        let accessToken: String; let refreshToken: String; let expiresAt: Date
        let email: String?; let displayName: String?
    }
    private struct Response: Decodable {
        struct User: Decodable { struct Metadata: Decodable { struct Claims: Decodable { let global_name: String? }; let custom_claims: Claims?; let full_name: String?; let name: String? }; let email: String?; let user_metadata: Metadata? }
        let access_token: String; let refresh_token: String; let expires_in: Int; let user: User?
    }
    private struct Redeemed: Decodable { let token: String }
    private let store: any LuaToolsCredentialStore
    private let transport: Transport
    private var generation: UInt64 = 0
    private var refresh: Task<Stored, Error>?
    private static let apiKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE3NzYwMzkzNzYsImV4cCI6MTg5MzQ1NjAwMCwicm9sZSI6ImFub24iLCJpc3MiOiJzdXBhYmFzZSJ9.f_-K38u3odjltP-g_67FVmG32Vg-_-k-lNBvIaVUVBM"

    public init() {
        store = KeychainCredentialStore()
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: AuthRedirectPolicy(), delegateQueue: nil)
        transport = { request in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.expectedContentLength <= 1_048_576 else { throw LuaToolsAuthenticationError.invalidResponse }
            var data = Data()
            for try await byte in bytes { guard data.count < 1_048_576 else { throw LuaToolsAuthenticationError.invalidResponse }; data.append(byte) }
            return (data, http.statusCode)
        }
    }
    @_spi(Testing) public init(store: any LuaToolsCredentialStore, transport: @escaping Transport) { self.store = store; self.transport = transport }

    public func account() throws -> LuaToolsAccount? {
        guard let stored = try load() else { return nil }
        return LuaToolsAccount(email: stored.email, displayName: stored.displayName)
    }
    public func signIn(code: String) async throws -> LuaToolsAccount {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.utf8.count == 6, normalized.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { throw LuaToolsAuthenticationError.invalidCode }
        generation &+= 1; let epoch = generation
        refresh?.cancel(); refresh = nil
        let data = try await Self.request(transport, url: "https://lua.tools/api/auth/code/redeem", body: ["code": normalized], apiKey: false)
        guard let redeemed = try? JSONDecoder().decode(Redeemed.self, from: data), !redeemed.token.isEmpty, redeemed.token.utf8.count <= 4096 else { throw LuaToolsAuthenticationError.invalidResponse }
        let verified = try await Self.request(transport, url: "https://db.lua.tools/auth/v1/verify", body: ["type": "magiclink", "token_hash": redeemed.token], apiKey: true)
        let session = try Self.decode(verified, previous: nil)
        guard generation == epoch else { throw LuaToolsAuthenticationError.sessionChanged }
        try store.write(JSONEncoder().encode(session))
        return LuaToolsAccount(email: session.email, displayName: session.displayName)
    }
    public func accessToken() async throws -> String {
        guard let stored = try load() else { throw LuaToolsAuthenticationError.signedOut }
        if stored.expiresAt > Date().addingTimeInterval(120) { return stored.accessToken }
        let epoch = generation, transport = self.transport
        let task = refresh ?? Task<Stored, Error> {
            let bytes = try await Self.request(transport, url: "https://db.lua.tools/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": stored.refreshToken], apiKey: true)
            return try Self.decode(bytes, previous: stored)
        }
        refresh = task
        do {
            let updated = try await task.value
            guard generation == epoch else { throw LuaToolsAuthenticationError.sessionChanged }
            try store.write(JSONEncoder().encode(updated)); refresh = nil
            return updated.accessToken
        } catch { if generation == epoch { refresh = nil }; throw error }
    }
    public func signOut() throws { generation &+= 1; refresh?.cancel(); refresh = nil; try store.remove() }

    private func load() throws -> Stored? {
        guard let data = try store.read() else { return nil }
        guard data.count <= 65_536, let session = try? JSONDecoder().decode(Stored.self, from: data), !session.accessToken.isEmpty, !session.refreshToken.isEmpty else { throw LuaToolsAuthenticationError.invalidResponse }
        return session
    }
    private static func decode(_ data: Data, previous: Stored?) throws -> Stored {
        guard let result = try? JSONDecoder().decode(Response.self, from: data), !result.access_token.isEmpty, !result.refresh_token.isEmpty,
              result.access_token.utf8.count <= 16_384, result.refresh_token.utf8.count <= 16_384,
              result.expires_in > 0, result.expires_in <= 31_536_000 else { throw LuaToolsAuthenticationError.invalidResponse }
        let metadata = result.user?.user_metadata
        return Stored(accessToken: result.access_token, refreshToken: result.refresh_token, expiresAt: Date().addingTimeInterval(TimeInterval(result.expires_in)),
                      email: result.user?.email ?? previous?.email, displayName: metadata?.custom_claims?.global_name ?? metadata?.full_name ?? metadata?.name ?? result.user?.email ?? previous?.displayName)
    }
    private static func request(_ transport: Transport, url: String, body: [String: String], apiKey: Bool) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if apiKey { request.setValue(Self.apiKey, forHTTPHeaderField: "apikey") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, status) = try await transport(request)
        guard (200..<300).contains(status) else { throw LuaToolsAuthenticationError.rejected(status) }
        guard data.count <= 1_048_576 else { throw LuaToolsAuthenticationError.invalidResponse }
        return data
    }
}

private final class AuthRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
