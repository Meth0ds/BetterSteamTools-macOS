import Foundation
import Network

public struct LocalHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}
public struct LocalHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int = 200, json: [String: any Sendable]) {
        self.status = status
        self.body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{\"success\":false,\"error\":\"JSON encoding failed\"}".utf8)
    }
    public static func error(_ code: Int, _ message: String) -> Self { .init(status: code, json: ["success": false, "error": message]) }
    public func encoded() -> Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 413: "Payload Too Large", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 501: "Not Implemented", 503: "Service Unavailable"][status] ?? "Error"
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8) + body
    }
}

/// One HTTP/1.x request per connection, with bounded headers and an exact Content-Length.
public struct LocalHTTPRequestParser: Sendable {
    public enum ParseError: Error, Equatable { case malformed, tooLarge }
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> LocalHTTPRequest? {
        guard buffer.count + data.count <= 1_048_576 + 16_384 else { throw ParseError.tooLarge }
        buffer.append(data)
        guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count <= 16_384 else { throw ParseError.tooLarge }
            return nil
        }
        guard boundary.lowerBound <= 16_384,
              let text = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else { throw ParseError.malformed }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(requestLine[2])),
              ["GET", "POST", "OPTIONS"].contains(String(requestLine[0])), requestLine[1].first == "/",
              !requestLine[1].contains("#"), !requestLine[1].contains("\\"), requestLine[1].count < 4096 else { throw ParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex, line.first?.isWhitespace != true else { throw ParseError.malformed }
            let key = line[..<colon].lowercased()
            guard key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[key] == nil else { throw ParseError.malformed }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw ParseError.malformed }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.allSatisfy(\.isNumber), let length = Int(rawLength), length >= 0 else { throw ParseError.malformed }
        guard length <= 1_048_576 else { throw ParseError.tooLarge }
        let bodyStart = boundary.upperBound
        guard buffer.count >= bodyStart + length else { return nil }
        guard buffer.count == bodyStart + length else { throw ParseError.malformed }
        guard let path = String(requestLine[1]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) else { throw ParseError.malformed }
        return LocalHTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: Data(buffer[bodyStart...]))
    }
}

public struct LocalAPIRouter: Sendable {
    public let installer: LuaInstaller
    public init(installer: LuaInstaller = LuaInstaller()) { self.installer = installer }
    public func handle(_ request: LocalHTTPRequest) -> LocalHTTPResponse {
        if let origin = request.headers["origin"], origin != "https://store.steampowered.com" { return .error(403, "Origin not allowed") }
        if let host = request.headers["host"] {
            guard ["127.0.0.1", "localhost", "[::1]"].contains(where: { host == $0 || host.hasPrefix($0 + ":") }) else { return .error(403, "Host not allowed") }
        }
        if request.method == "OPTIONS" { return .error(405, "Use the LuaTools local bridge") }
        if request.path == "/health", request.method == "GET" {
            return .init(json: ["success": true, "service": "luatools", "apiVersion": 1, "platform": "macos-arm64", "capabilities": ["has", "remove"]])
        }
        let components = request.path.split(separator: "/", omittingEmptySubsequences: false)
        if components.count == 3, ["has", "remove"].contains(components[1]) {
            let rawID = String(components[2])
            guard !rawID.isEmpty, rawID.allSatisfy(\.isNumber), let id = UInt32(rawID), components[1] == "has" || id > 0 else { return .error(400, "Invalid AppID") }
            do {
                switch (request.method, components[1]) {
                case ("GET", "has"): return .init(json: ["success": true, "exists": installer.hasLua(appID: Int(id))])
                case ("POST", "remove"):
                    try installer.removeLua(appID: Int(id))
                    return .init(json: ["success": true])
                default: return .error(405, "Method not allowed")
                }
            } catch { return .error(500, error.localizedDescription) }
        }
        let notYetImplemented = ["add", "add-status", "add-source", "download", "download-status", "check-sources", "cancel", "open", "open-url", "restart-steam", "check-updates", "loaded-apps", "api-list", "icon", "settings", "themes", "init-message", "translations", "games-database", "fixes", "log"]
        if components.count > 1, notYetImplemented.contains(String(components[1])) { return .error(501, "This capability is not available in this build") }
        return .error(404, "Not found")
    }
}

/// The listener binds explicitly to IPv4 loopback. It never exposes plugin actions on the LAN.
public final class LocalAPIServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.luatools.local-api")
    private let router: LocalAPIRouter
    private var connections: [UUID: NWConnection] = [:]
    private var startup: CheckedContinuation<UInt16, Error>?
    private var started = false
    public init(installer: LuaInstaller = LuaInstaller(), port: UInt16 = 6767) throws {
        self.router = LocalAPIRouter(installer: installer)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        self.listener = try NWListener(using: parameters)
    }
    @discardableResult public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !self.started else { continuation.resume(throwing: LuaToolsError.invalidRequest); return }
                self.started = true
                self.startup = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port else { return }
                        self.startup?.resume(returning: port.rawValue); self.startup = nil
                    case .failed(let error): self.startup?.resume(throwing: error); self.startup = nil; self.listener.cancel()
                    case .cancelled: self.startup?.resume(throwing: CancellationError()); self.startup = nil
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener.start(queue: self.queue)
            }
        }
    }
    public func stop() {
        queue.async {
            self.listener.cancel()
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 32 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.connections[id] != nil { connection.cancel() }
        }
        receive(connection, parser: LocalHTTPRequestParser())
    }
    private func receive(_ connection: NWConnection, parser: LocalHTTPRequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            guard error == nil else { connection.cancel(); return }
            var next = parser
            do {
                if let request = try next.append(data ?? Data()) {
                    self.send(connection, self.router.handle(request)); return
                }
                if complete { self.send(connection, .error(400, "Incomplete request")); return }
                self.receive(connection, parser: next)
            } catch LocalHTTPRequestParser.ParseError.tooLarge { self.send(connection, .error(413, "Request too large")) }
            catch { self.send(connection, .error(400, "Malformed request")) }
        }
    }
    private func send(_ connection: NWConnection, _ response: LocalHTTPResponse) {
        connection.send(content: response.encoded(), completion: .contentProcessed { _ in connection.cancel() })
    }
}
