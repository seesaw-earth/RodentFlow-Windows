// SyncImport.swift — the reading side of SyncPackage: finding packages in the sync folder and copying a
// complete one into the app's own storage. Used by the Mac (phone data import); Foundation only, so it is
// tested on Linux together with the writing side.
//
// Order of safety checks:
//   1. discover   – package folders and their manifests (cheap; run on every scan)
//   2. stage      – only for packages that are new or have a newer revision: every file is checked against
//                   the manifest (SyncPackage.check), copied into a temporary folder, checked AGAIN after the
//                   copy (a file that changed while it was copied is caught here) and only then moved to its
//                   final place. A failed or partial copy never leaves anything behind.

import Foundation

enum SyncImport {
    /// A package found in the sync folder.
    struct Found {
        var url: URL
        /// nil when the manifest is missing (still syncing) or unreadable.
        var manifest: SyncManifest?
        var problem: String?
    }

    enum StageError: LocalizedError, Equatable {
        case notReady(SyncPackage.Status)
        case changedWhileCopying(String)
        case destinationExists

        var errorDescription: String? {
            switch self {
            case .notReady(.incomplete(let name)):
                return L("Still syncing (", "仍在同步（") + name + L("); it is imported when complete.", "）；完成后会自动导入。")
            case .notReady(.damaged(let name)):
                return L("The package is damaged (", "数据包已损坏（") + name + L("). Sync it again from the phone.", "）。请在手机上重新同步。")
            case .notReady(.unsupported(let format)):
                return String(format: L("Written by a newer RodentFlow (format %d). Update RodentFlow on the Mac.",
                                        "由更新版本的 RodentFlow 写入（格式 %d）。请更新 Mac 版 RodentFlow。"), format)
            case .notReady(.ready):
                return nil
            case .changedWhileCopying(let name):
                return L("The package changed while it was copied (", "复制过程中数据包发生了变化（") + name + L("); it is tried again.", "）；稍后会重试。")
            case .destinationExists:
                return L("The import folder already exists.", "导入文件夹已存在。")
            }
        }
    }

    /// Package folders under `root` with their manifests (no checksums: cheap enough for every scan).
    static func discover(root: URL) -> [Found] {
        SyncPackage.scan(root).map { url in
            let manifestURL = url.appendingPathComponent(SyncManifest.fileName)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                return Found(url: url, manifest: nil, problem: SyncManifest.fileName)
            }
            do {
                return Found(url: url, manifest: try SyncPackage.readManifest(url), problem: nil)
            } catch {
                return Found(url: url, manifest: nil, problem: error.localizedDescription)
            }
        }
    }

    /// Whether a package holds something newer than what was imported. `imported` maps record ids (one per
    /// animal / chamber) to the revision imported for them.
    static func needsImport(_ manifest: SyncManifest, imported: [UUID: Date]) -> Bool {
        guard !manifest.records.isEmpty else { return false }
        return manifest.records.contains { r in
            guard let have = imported[r.recordID] else { return true }
            return manifest.revision > have
        }
    }

    /// Copies a complete package into `destination` (which must not exist yet): every file listed in the
    /// manifest plus the manifest itself (as `manifestCopyName`). Returns the manifest that was copied.
    @discardableResult
    static func stage(_ package: URL, into destination: URL, manifestCopyName: String = "phone_manifest.json") throws -> SyncManifest {
        let fm = FileManager.default
        let (checked, status) = SyncPackage.check(package)
        guard status == .ready, let manifest = checked else { throw StageError.notReady(status) }
        guard !fm.fileExists(atPath: destination.path) else { throw StageError.destinationExists }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent("." + destination.lastPathComponent + ".staging-" + UUID().uuidString.prefix(8),
                                                 isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        do {
            try coordinatedRead(package) { source in
                for name in manifest.files.keys.sorted() {
                    try fm.copyItem(at: source.appendingPathComponent(name), to: temp.appendingPathComponent(name))
                }
                try fm.copyItem(at: source.appendingPathComponent(SyncManifest.fileName),
                                to: temp.appendingPathComponent(manifestCopyName))
            }
            // The copy must match the manifest exactly (a file replaced during the copy is caught here).
            for (name, info) in manifest.files {
                let copied = try SyncPackage.fileInfo(temp.appendingPathComponent(name))
                guard copied.size == info.size, info.checksum.isEmpty || copied.checksum == info.checksum else {
                    throw StageError.changedWhileCopying(name)
                }
            }
            try fm.moveItem(at: temp, to: destination)
            return manifest
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Reads under file coordination where the platform has it (iCloud Drive and other file providers
    /// then deliver the current, fully downloaded version).
    private static func coordinatedRead(_ url: URL, _ body: (URL) throws -> Void) throws {
        #if canImport(Darwin)
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do { try body(readURL) } catch { bodyError = error }
        }
        if let e = coordinationError ?? bodyError { throw e }
        #else
        try body(url)
        #endif
    }

    /// Asks iCloud Drive to download the files of a package that are still only in the cloud
    /// (".name.icloud" placeholders). Harmless elsewhere.
    static func requestDownload(_ package: URL) {
        #if os(macOS) || os(iOS)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: package.path) else {
            try? fm.startDownloadingUbiquitousItem(at: package)
            return
        }
        for name in names where name.hasPrefix(".") && name.hasSuffix(".icloud") {
            let real = String(name.dropFirst().dropLast(".icloud".count))
            try? fm.startDownloadingUbiquitousItem(at: package.appendingPathComponent(real))
        }
        #endif
    }
}
