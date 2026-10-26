import Foundation
import CryptoKit

/// Wire format shared by the installer and the injected native runtime.
public struct BuildApproval: Sendable {
    public struct Payload: Codable, Sendable, Equatable {
        public let schema: Int
        public let build: String
        public let architecture: String
        public let files: [String: String]
        public let payloadSHA256: String
        public init(build: String, files: [String: String], payloadSHA256: String) {
            schema = 1; self.build = build; architecture = "arm64"
            self.files = files; self.payloadSHA256 = payloadSHA256
        }
    }
    public struct Envelope: Codable, Sendable {
        public let keyID: String
        public let payload: Data
        public let signature: Data
        public init(keyID: String, payload: Data, signature: Data) {
            self.keyID = keyID; self.payload = payload; self.signature = signature
        }
    }
    public enum Failure: Error, LocalizedError {
        case invalidManifest, untrustedKey, invalidSignature, invalidPayload, fileMismatch(String), invalidFile(String)
        public var errorDescription: String? {
            switch self {
            case .invalidManifest: "Manifiesto ausente, demasiado grande o mal formado."
            case .untrustedKey: "La clave del manifiesto no pertenece al almacén de confianza de esta build."
            case .invalidSignature: "La firma Ed25519 del manifiesto no es válida."
            case .invalidPayload: "El manifiesto no describe una build macOS arm64 admitida."
            case .fileMismatch(let name): "SHA-256 distinto al aprobado: \(name)."
            case .invalidFile(let name): "Archivo ausente, no regular, enlazado o fuera de los límites: \(name)."
            }
        }
    }
    public let payload: Payload
    public let envelope: Data
    public static let fileNames: Set<String> = ["steam_osx", "steamclient.dylib", "steamui.dylib"]
    public static func verify(_ data: Data, trustedKeys: [String: Data]) throws -> Self {
        guard !data.isEmpty, data.count <= 1_048_576,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw Failure.invalidManifest }
        guard let bytes = trustedKeys[envelope.keyID], bytes.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else { throw Failure.untrustedKey }
        guard envelope.signature.count == 64, key.isValidSignature(envelope.signature, for: envelope.payload) else { throw Failure.invalidSignature }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: envelope.payload),
              payload.schema == 1, payload.architecture == "arm64", !payload.build.isEmpty, payload.build.utf8.count <= 64,
              payload.build.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              Set(payload.files.keys) == fileNames, payload.files.values.allSatisfy(validHash), validHash(payload.payloadSHA256) else { throw Failure.invalidPayload }
        return Self(payload: payload, envelope: data)
    }
    public func validate(clientDirectory: URL, dylib: URL? = nil) throws {
        for name in Self.fileNames.sorted() {
            guard try Self.hashFile(clientDirectory.appendingPathComponent(name)) == payload.files[name] else { throw Failure.fileMismatch(name) }
        }
        if let dylib, try Self.hashFile(dylib) != payload.payloadSHA256 { throw Failure.fileMismatch(dylib.lastPathComponent) }
    }
    /// Streaming hashing bounds memory use even for a large Steam client.
    public static func hashFile(_ url: URL, maximumSize: UInt64 = 536_870_912) throws -> String {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let size = properties.fileSize, size >= 0, UInt64(size) <= maximumSize else { throw Failure.invalidFile(url.lastPathComponent) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256(), total: UInt64 = 0
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            total += UInt64(data.count)
            guard total <= maximumSize else { throw Failure.invalidFile(url.lastPathComponent) }
            digest.update(data: data)
        }
        guard total == UInt64(size) else { throw Failure.invalidFile(url.lastPathComponent) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func validHash(_ string: String) -> Bool {
        string.utf8.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
