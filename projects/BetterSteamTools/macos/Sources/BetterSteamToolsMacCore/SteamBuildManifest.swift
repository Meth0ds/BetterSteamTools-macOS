import Foundation
import CryptoKit
import BSTBuildApproval

/// Hashes identify a build; Ed25519 authenticates who approved those hashes.
/// An empty trust store deliberately approves no release manifests.
public struct SteamBuildManifest: Sendable {
    public typealias Payload = BuildApproval.Payload
    public typealias Envelope = BuildApproval.Envelope
    public static let releaseKeys: [String: Data] = [:]
    public let approved: Payload
    public let envelope: Data
    private init(approved: Payload, envelope: Data) { self.approved = approved; self.envelope = envelope }
    public static func load(from url: URL, trustedKeys: [String: Data] = Self.releaseKeys) throws -> Self {
        guard let properties = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              properties.isRegularFile == true, properties.isSymbolicLink != true,
              let size = properties.fileSize, size > 0, size <= 1_048_576 else { throw BundleError.invalidManifest }
        return try verify(Data(contentsOf: url), trustedKeys: trustedKeys)
    }
    public static func verify(_ data: Data, trustedKeys: [String: Data] = Self.releaseKeys) throws -> Self {
        guard let approval = try? BuildApproval.verify(data, trustedKeys: trustedKeys) else { throw BundleError.invalidManifest }
        return Self(approved: approval.payload, envelope: data)
    }
    public func validate(paths: SteamPaths = .detected, dylib: URL? = nil) -> Bool {
        for (name, expected) in approved.files {
            let url = paths.clientDirectory.appendingPathComponent(name)
            guard let actual = try? Self.hashFile(url), actual == expected else { return false }
        }
        if let dylib { return (try? Self.hashFile(dylib)) == approved.payloadSHA256 }
        return true
    }
    public static func hashFile(_ url: URL) throws -> String {
        try BuildApproval.hashFile(url)
    }
}
