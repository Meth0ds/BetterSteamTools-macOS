import Foundation
import Darwin

/// Journals and snapshots are private to one canonical Steam.app. Recovery
/// compares both sides of the swap before moving anything: a later external
/// change is a conflict, never permission to overwrite the user's bundle.
struct SteamBundleTransaction {
    let paths: SteamPaths
    let stateDirectory: URL
    let signer: SteamBundleInstaller.Signer
    let isSteamRunning: @Sendable () -> Bool
    let observer: SteamBundleInstaller.Observer
    private var app: URL { paths.steamApp }
    private var receiptURL: URL { stateDirectory.appendingPathComponent("receipt-v2.json") }
    private var journalURL: URL { stateDirectory.appendingPathComponent("transaction-v2.json") }
    private var snapshot: URL { stateDirectory.appendingPathComponent("Original.app") }
    private var payload: URL { app.appendingPathComponent("Contents/MacOS/BetterSteamTools.dylib") }
    private var approval: URL { app.appendingPathComponent("Contents/Resources/BetterSteamTools.build.json") }
    private struct Receipt: Codable {
        let schema: Int
        let bundle: String
        let originalTree: String
        let installedTree: String
        let originalPlist: Data
        let installedPlist: Data
        let payloadSHA256: String
        let approvalSHA256: String
    }
    private struct Journal: Codable {
        enum Phase: String, Codable { case staging, prepared, committed, cleaning, rolledBack }
        let schema: Int
        let bundle: String
        let stageName: String
        let previousTree: String
        var nextTree: String?
        let previousReceipt: Data?
        var nextReceipt: Data?
        let hadSnapshot: Bool
        var phase: Phase
    }
    func install(dylib: URL, manifest: SteamBuildManifest, dryRun: Bool) throws {
        try preflight()
        try BundleFileSystem.requireRegular(dylib)
        guard let size = try dylib.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 536_870_912 else { throw BundleError.invalidDylib }
        let bytes = try Data(contentsOf: dylib)
        guard bytes.count <= 536_870_912,
              (try? ExecutableImage.machOSlices(bytes).contains(where: \.isArm64Dylib)) == true else { throw BundleError.invalidDylib }
        guard manifest.validate(paths: paths, dylib: dylib) else { throw BundleError.invalidManifest }
        if dryRun {
            try refuseForeignFiles(receipt: loadReceipt())
            return
        }
        try locked {
            try recoverLocked()
            let previous = try loadReceipt()
            try refuseForeignFiles(receipt: previous)
            if let previous, previous.payloadSHA256 == manifest.approved.payloadSHA256,
               previous.approvalSHA256 == BundleFileSystem.hash(manifest.envelope),
               try BundleFileSystem.fingerprint(app) == previous.installedTree { return }
            try change(previous: previous) { stage, originalTree, before in
                let stagedPayload = stage.appendingPathComponent("Contents/MacOS/BetterSteamTools.dylib")
                let stagedApproval = stage.appendingPathComponent("Contents/Resources/BetterSteamTools.build.json")
                let stagedPlist = stage.appendingPathComponent("Contents/Info.plist")
                var dictionary = try Self.dictionary(before)
                var seen: Set<String> = []
                let insertion = (try Self.libraries(in: before) + [payload.path]).filter { seen.insert($0).inserted }
                var environment = dictionary["LSEnvironment"] as? [String: Any] ?? [:]
                environment["DYLD_INSERT_LIBRARIES"] = insertion.joined(separator: ":")
                dictionary["LSEnvironment"] = environment
                let installedPlist = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
                try FileManager.default.createDirectory(at: stagedApproval.deletingLastPathComponent(), withIntermediateDirectories: true)
                try BundleFileSystem.atomicWrite(bytes, to: stagedPayload)
                try BundleFileSystem.atomicWrite(manifest.envelope, to: stagedApproval)
                try BundleFileSystem.atomicWrite(installedPlist, to: stagedPlist)
                try signer(stage)
                guard try SteamBuildManifest.hashFile(stagedPayload) == manifest.approved.payloadSHA256,
                      try Data(contentsOf: stagedApproval) == manifest.envelope,
                      try Data(contentsOf: stagedPlist) == installedPlist,
                      manifest.validate(paths: paths, dylib: dylib) else { throw BundleError.invalidManifest }
                return Receipt(schema: 2, bundle: app.path, originalTree: originalTree,
                               installedTree: try BundleFileSystem.fingerprint(stage),
                               originalPlist: previous?.originalPlist ?? before, installedPlist: installedPlist,
                               payloadSHA256: manifest.approved.payloadSHA256,
                               approvalSHA256: BundleFileSystem.hash(manifest.envelope))
            }
        }
    }
    func uninstall(dryRun: Bool) throws {
        try preflight()
        if dryRun { if let receipt = try loadReceipt() { try verifyOwnedFiles(receipt) }; return }
        try locked {
            try recoverLocked()
            guard let previous = try loadReceipt() else { return }
            try verifyOwnedFiles(previous)
            try change(previous: previous) { stage, _, before in
                if try BundleFileSystem.fingerprint(app) == previous.installedTree {
                    // Replace the staged clone with the exact pre-install bundle,
                    // including its original signed executable and signature seal.
                    try BundleFileSystem.remove(stage)
                    try BundleFileSystem.clone(snapshot, to: stage)
                    guard try BundleFileSystem.fingerprint(stage) == previous.originalTree else { throw BundleError.recoveryConflict }
                } else {
                    // Retain later NotProton/Steam/user modifications. The old
                    // signature cannot seal a changed bundle, so sign this merge.
                    let restored: Data
                    if before == previous.installedPlist { restored = previous.originalPlist }
                    else {
                        var dictionary = try Self.dictionary(before)
                        var environment = dictionary["LSEnvironment"] as? [String: Any] ?? [:]
                        let libraries = try Self.libraries(in: before).filter { $0 != payload.path }
                        if libraries.isEmpty { environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES") }
                        else { environment["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":") }
                        if environment.isEmpty { dictionary.removeValue(forKey: "LSEnvironment") }
                        else { dictionary["LSEnvironment"] = environment }
                        restored = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
                    }
                    try BundleFileSystem.atomicWrite(restored, to: stage.appendingPathComponent("Contents/Info.plist"))
                    try BundleFileSystem.remove(stage.appendingPathComponent("Contents/MacOS/BetterSteamTools.dylib"))
                    try BundleFileSystem.remove(stage.appendingPathComponent("Contents/Resources/BetterSteamTools.build.json"))
                    try signer(stage)
                }
                return nil
            }
        }
    }
    func recover() throws { try preflight(); try locked { try recoverLocked() } }

    private func change(previous: Receipt?, prepare: (URL, String, Data) throws -> Receipt?) throws {
        let beforeTree = try BundleFileSystem.fingerprint(app)
        let beforePlist = try Data(contentsOf: paths.infoPlist)
        let previousData = try read(receiptURL)
        let stage = app.deletingLastPathComponent().appendingPathComponent(".bst-stage-\(UUID().uuidString).app")
        let hadSnapshot = try BundleFileSystem.status(snapshot) != nil
        if previous != nil {
            guard hadSnapshot, try BundleFileSystem.fingerprint(snapshot) == previous!.originalTree else { throw BundleError.invalidReceipt }
        } else if hadSnapshot { throw BundleError.invalidReceipt }
        var journal = Journal(schema: 2, bundle: app.path, stageName: stage.lastPathComponent, previousTree: beforeTree,
                              nextTree: nil, previousReceipt: previousData, nextReceipt: nil,
                              hadSnapshot: hadSnapshot, phase: .staging)
        try write(journal, to: journalURL)
        do {
            try observer(.staging)
            if !hadSnapshot { try BundleFileSystem.clone(app, to: snapshot); try BundleFileSystem.syncTree(snapshot) }
            let originalTree = previous?.originalTree ?? beforeTree
            guard try BundleFileSystem.fingerprint(snapshot) == originalTree else { throw BundleError.recoveryConflict }
            try BundleFileSystem.clone(app, to: stage)
            let next = try prepare(stage, originalTree, beforePlist)
            try BundleFileSystem.syncTree(stage)
            let nextTree = try BundleFileSystem.fingerprint(stage)
            guard next == nil || next?.installedTree == nextTree,
                  !isSteamRunning(), try BundleFileSystem.fingerprint(app) == beforeTree else { throw BundleError.recoveryConflict }
            journal.nextTree = nextTree
            journal.nextReceipt = try next.map { try JSONEncoder().encode($0) }
            journal.phase = .prepared
            try write(journal, to: journalURL)
            try observer(.prepared)
            guard !isSteamRunning(), try BundleFileSystem.fingerprint(app) == beforeTree else { throw BundleError.recoveryConflict }
            try BundleFileSystem.swap(app, stage)
            try observer(.swapped)
            try persistReceipt(journal.nextReceipt)
            try observer(.receiptPersisted)
            journal.phase = .committed
            try write(journal, to: journalURL)
            try observer(.committed)
            try finishCommitted(journal, stage: stage)
        } catch {
            let failure = error
            do { try recoverLocked() }
            catch { throw BundleError.rollbackFailed(failure.localizedDescription + "; " + error.localizedDescription) }
            throw failure
        }
    }
    private func recoverLocked() throws {
        guard let bytes = try read(journalURL) else { return }
        guard let journal = try? JSONDecoder().decode(Journal.self, from: bytes), journal.schema == 2,
              journal.bundle == app.path, journal.stageName.hasPrefix(".bst-stage-"), journal.stageName.hasSuffix(".app"),
              !journal.stageName.contains("/"), UUID(uuidString: String(journal.stageName.dropFirst(11).dropLast(4))) != nil,
              validHash(journal.previousTree), journal.nextTree.map(validHash) ?? (journal.phase == .staging) else { throw BundleError.invalidReceipt }
        let stage = app.deletingLastPathComponent().appendingPathComponent(journal.stageName)
        try BundleFileSystem.refuseSymlinks(stage, inside: stage.deletingLastPathComponent())
        if journal.phase == .committed || journal.phase == .cleaning { try finishCommitted(journal, stage: stage); return }
        if journal.phase == .rolledBack { try finishRollback(journal, stage: stage); return }
        let current = try BundleFileSystem.fingerprint(app)
        if journal.phase == .staging {
            guard current == journal.previousTree else { throw BundleError.recoveryConflict }
        } else {
            guard let next = journal.nextTree, let stageStatus = try BundleFileSystem.status(stage), stageStatus.st_mode & S_IFMT == S_IFDIR else { throw BundleError.recoveryConflict }
            let other = try BundleFileSystem.fingerprint(stage)
            if current == next && other == journal.previousTree { try BundleFileSystem.swap(app, stage) }
            else if current != journal.previousTree || other != next { throw BundleError.recoveryConflict }
        }
        var settled = journal; settled.phase = .rolledBack
        try write(settled, to: journalURL)
        try finishRollback(settled, stage: stage)
    }
    private func finishCommitted(_ journal: Journal, stage: URL) throws {
        guard let next = journal.nextTree, try BundleFileSystem.fingerprint(app) == next else { throw BundleError.recoveryConflict }
        if journal.phase == .committed {
            if try BundleFileSystem.status(stage) != nil {
                guard try BundleFileSystem.fingerprint(stage) == journal.previousTree else { throw BundleError.recoveryConflict }
            }
            var cleaning = journal; cleaning.phase = .cleaning
            try write(cleaning, to: journalURL)
        }
        // Once cleanup is journaled, interrupted recursive deletion is safe to
        // resume without mistaking the partially deleted owned stage for drift.
        try BundleFileSystem.remove(stage)
        try persistReceipt(journal.nextReceipt)
        if journal.nextReceipt == nil { try BundleFileSystem.remove(snapshot) }
        try BundleFileSystem.remove(journalURL)
    }
    private func finishRollback(_ journal: Journal, stage: URL) throws {
        guard try BundleFileSystem.fingerprint(app) == journal.previousTree else { throw BundleError.recoveryConflict }
        try persistReceipt(journal.previousReceipt)
        try BundleFileSystem.remove(stage)
        if !journal.hadSnapshot { try BundleFileSystem.remove(snapshot) }
        try BundleFileSystem.remove(journalURL)
    }
    private func persistReceipt(_ bytes: Data?) throws {
        if let bytes { try BundleFileSystem.atomicWrite(bytes, to: receiptURL) }
        else { try BundleFileSystem.remove(receiptURL) }
    }
    private func refuseForeignFiles(receipt: Receipt?) throws {
        if let receipt { try verifyOwnedFiles(receipt) }
        else if try BundleFileSystem.status(payload) != nil || BundleFileSystem.status(approval) != nil { throw BundleError.foreignPayload }
    }
    private func verifyOwnedFiles(_ receipt: Receipt) throws {
        guard (try? SteamBuildManifest.hashFile(payload)) == receipt.payloadSHA256,
              (try? SteamBuildManifest.hashFile(approval)) == receipt.approvalSHA256 else { throw BundleError.payloadChanged }
    }
    private func loadReceipt() throws -> Receipt? {
        guard let bytes = try read(receiptURL) else { return nil }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: bytes), receipt.schema == 2,
              receipt.bundle == app.path, validHash(receipt.originalTree), validHash(receipt.installedTree),
              validHash(receipt.payloadSHA256), validHash(receipt.approvalSHA256) else { throw BundleError.invalidReceipt }
        return receipt
    }
    private func preflight() throws {
        guard !isSteamRunning() else { throw BundleError.steamRunning }
        guard try BundleFileSystem.status(paths.infoPlist) != nil else { throw BundleError.steamMissing }
        // Canonicalize ancestors such as /var -> /private/var but refuse links
        // at or inside the selected app, state directory or payload locations.
        try BundleFileSystem.refuseSymlinks(paths.infoPlist, inside: app)
        try BundleFileSystem.refuseSymlinks(payload, inside: app)
        try BundleFileSystem.refuseSymlinks(approval, inside: app)
        try BundleFileSystem.refuseSymlinks(stateDirectory, inside: stateDirectory)
        if let info = try BundleFileSystem.status(app), info.st_mode & S_IFMT != S_IFDIR { throw BundleError.steamMissing }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let info = try BundleFileSystem.status(stateDirectory), info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw BundleError.invalidReceipt }
        let lockURL = stateDirectory.appendingPathComponent("operation.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw BundleFileSystem.posix("open transaction lock", lockURL) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw BundleError.recoveryConflict }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    private func read(_ url: URL) throws -> Data? {
        guard let info = try BundleFileSystem.status(url) else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 16_777_216 else { throw BundleError.invalidReceipt }
        return try Data(contentsOf: url)
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws { try BundleFileSystem.atomicWrite(JSONEncoder().encode(value), to: url) }
    private func validHash(_ string: String) -> Bool { string.utf8.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              dictionary["LSEnvironment"] == nil || dictionary["LSEnvironment"] is [String: Any] else { throw BundleError.invalidPlist }
        return dictionary
    }
    static func libraries(in data: Data) throws -> [String] {
        let environment = try dictionary(data)["LSEnvironment"] as? [String: Any] ?? [:]
        guard environment["DYLD_INSERT_LIBRARIES"] == nil || environment["DYLD_INSERT_LIBRARIES"] is String else { throw BundleError.invalidPlist }
        return (environment["DYLD_INSERT_LIBRARIES"] as? String ?? "").split(separator: ":").map(String.init)
    }
}
