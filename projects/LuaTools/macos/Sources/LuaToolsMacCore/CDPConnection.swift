import Foundation

/// A JSON tree that can cross actor boundaries without passing mutable Foundation objects.
public enum BridgeJSON: Sendable, Codable, Equatable {
    case object([String: BridgeJSON]), array([BridgeJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? value.decode([String: BridgeJSON].self) { self = .object(v) }
        else { self = .array(try value.decode([BridgeJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public subscript(_ key: String) -> BridgeJSON? { if case .object(let v) = self { return v[key] }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var integer: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v, v >= Double(Int32.min), v <= Double(Int32.max) else { return nil }
        return Int(v)
    }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

public enum CDPError: LocalizedError, Sendable {
    case invalidEndpoint, closed, timeout(String), protocolError(String), remote(String), script(String)
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "El inspector de Steam debe usar una dirección local válida."
        case .closed: "Se ha cerrado la conexión con el inspector de Steam."
        case .timeout(let method): "El inspector no respondió a \(method)."
        case .protocolError(let message): "Respuesta CDP no válida: \(message)"
        case .remote(let message): "Error del inspector: \(message)"
        case .script(let message): "El plugin no pudo ejecutarse: \(message)"
        }
    }
}

/// One reader owns the socket. Responses are correlated by ID, independently of notifications
/// and of the order in which requests finish. A timeout/cancellation removes its continuation.
public actor CDPConnection {
    public typealias EventSink = @Sendable (BridgeJSON) async -> Void
    private struct Pending {
        let continuation: CheckedContinuation<BridgeJSON, Error>
        let timer: Task<Void, Never>
    }
    private let socket: URLSessionWebSocketTask
    private let session: URLSession
    private var reader: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var sink: EventSink?
    private var closed = false
    public init(url: URL) throws {
        guard Self.isLoopback(url, schemes: ["ws"]), url.port != nil else { throw CDPError.invalidEndpoint }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 2_097_152
    }
    public static func isLoopback(_ url: URL, schemes: Set<String>) -> Bool {
        guard let scheme = url.scheme, schemes.contains(scheme), let host = url.host,
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host), url.user == nil, url.password == nil,
              url.fragment == nil else { return false }
        return true
    }
    public func start(events: EventSink? = nil) {
        guard reader == nil, !closed else { return }
        sink = events
        socket.resume()
        reader = Task { [weak self, socket] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self else { return }
                    try await self.receive(message)
                }
            } catch { await self?.close(error: error) }
        }
    }
    public func request(_ method: String, params: [String: BridgeJSON] = [:], timeout: Duration = .seconds(5)) async throws -> BridgeJSON {
        guard !closed, reader != nil else { throw CDPError.closed }
        guard pending.count < 64 else { throw CDPError.protocolError("too many outstanding requests") }
        nextID += 1
        let id = nextID
        let payload = try BridgeJSON.object(["id": .number(Double(id)), "method": .string(method), "params": .object(params)]).encoded()
        guard payload.utf8.count <= 2_097_152 else { throw CDPError.protocolError("request too large") }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.finish(id, result: .failure(CDPError.timeout(method)))
                }
                pending[id] = Pending(continuation: continuation, timer: timer)
                Task { [weak self, socket] in
                    do { try await socket.send(.string(payload)) }
                    catch { await self?.close(error: error) }
                }
            }
        } onCancel: {
            Task { await self.finish(id, result: .failure(CancellationError())) }
        }
    }
    public func evaluate(_ expression: String, contextID: Int? = nil) async throws -> BridgeJSON {
        var params: [String: BridgeJSON] = ["expression": .string(expression), "returnByValue": .bool(true), "awaitPromise": .bool(true)]
        if let contextID { params["contextId"] = .number(Double(contextID)) }
        let response = try await request("Runtime.evaluate", params: params)
        if let exception = response["exceptionDetails"] {
            throw CDPError.script(exception["exception"]?["description"]?.string ?? exception["text"]?.string ?? "JavaScript exception")
        }
        guard let value = response["result"]?["value"] else { throw CDPError.protocolError("Runtime.evaluate omitted its value") }
        return value
    }
    private func receive(_ message: URLSessionWebSocketTask.Message) async throws {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw CDPError.protocolError("unknown WebSocket message")
        }
        let json = try JSONDecoder().decode(BridgeJSON.self, from: data)
        if let id = json["id"]?.integer {
            if let error = json["error"] { finish(id, result: .failure(CDPError.remote(error["message"]?.string ?? "unknown error"))) }
            else if let result = json["result"] { finish(id, result: .success(result)) }
            else { throw CDPError.protocolError("response has neither result nor error") }
        } else if json["method"]?.string != nil { await sink?(json) }
        else { throw CDPError.protocolError("missing ID and method") }
    }
    private func finish(_ id: Int, result: Result<BridgeJSON, Error>) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timer.cancel()
        item.continuation.resume(with: result)
    }
    public func close(error: any Error = CDPError.closed) {
        guard !closed else { return }
        closed = true
        reader?.cancel(); reader = nil; sink = nil
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
    }
}
