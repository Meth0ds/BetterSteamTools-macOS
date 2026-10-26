import Foundation

/// The trusted key comes from the native build, never the manifest or an
/// environment variable. No key means no approval, including developer builds.
@_cdecl("BSTVerifyBuildManifest")
public func verifyRuntimeBuild(_ manifestPath: UnsafePointer<CChar>?, _ clientDirectory: UnsafePointer<CChar>?,
                               _ dylibPath: UnsafePointer<CChar>?, _ keyID: UnsafePointer<CChar>?,
                               _ publicKeyHex: UnsafePointer<CChar>?, _ expectedBuild: UnsafePointer<CChar>?,
                               _ diagnostic: UnsafeMutablePointer<CChar>?, _ diagnosticCapacity: Int) -> Int32 {
    func report(_ message: String) {
        guard let diagnostic, diagnosticCapacity > 0 else { return }
        let bytes = Array(message.utf8.prefix(diagnosticCapacity - 1))
        for (index, byte) in bytes.enumerated() { diagnostic[index] = CChar(bitPattern: byte) }
        diagnostic[bytes.count] = 0
    }
    do {
        guard let manifestPath, let clientDirectory, let dylibPath, let keyID, let publicKeyHex, let expectedBuild else { throw BuildApproval.Failure.invalidManifest }
        let hex = String(cString: publicKeyHex), identifier = String(cString: keyID)
        guard hex.utf8.count == 64, !identifier.isEmpty else { throw BuildApproval.Failure.untrustedKey }
        var key = Data(); var offset = hex.startIndex
        while offset != hex.endIndex {
            let end = hex.index(offset, offsetBy: 2)
            guard let byte = UInt8(hex[offset..<end], radix: 16) else { throw BuildApproval.Failure.untrustedKey }
            key.append(byte); offset = end
        }
        let manifestURL = URL(fileURLWithPath: String(cString: manifestPath))
        let properties = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let size = properties.fileSize, size > 0, size <= 1_048_576 else { throw BuildApproval.Failure.invalidManifest }
        let bytes = try Data(contentsOf: manifestURL)
        let approval = try BuildApproval.verify(bytes, trustedKeys: [identifier: key])
        guard approval.payload.build == String(cString: expectedBuild) else { throw BuildApproval.Failure.invalidPayload }
        try approval.validate(clientDirectory: URL(fileURLWithPath: String(cString: clientDirectory)),
                              dylib: URL(fileURLWithPath: String(cString: dylibPath)))
        report("Build arm64 y payload aprobados por manifiesto Ed25519.")
        return 1
    } catch { report(error.localizedDescription); return 0 }
}
