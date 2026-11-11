// SyncPackage.swift — how a finished analysis travels from the iPhone / iPad to the Mac.
//
// The phone writes one folder package per analysis into a folder the researcher chose once on each
// device (normally the same iCloud Drive folder; any shared folder works, also a USB stick or AirDrop):
//
//   <chosen folder>/RodentFlow Sync/<device>/<id>.rfsession/
//       manifest.json   what it is: task, method, animal(s), the phone's own numbers, file checksums
//       …               the data itself (pose session + keypoints, centroid tracking, TST recording)
//
// The Mac scans the folder at launch, whenever it changes and on request, imports every new or
// updated package into the matching task / group / animal, recomputes the results with the same
// shared code and compares them with the phone's numbers (consistency check).
//
// Safety: a package is written into a temporary folder and renamed when complete; the manifest
// lists every file with its size and checksum, so a package that is still being synced (iCloud) or
// was damaged is never imported half-way. Imports copy the package into the Mac's own storage, so
// removing files from the sync folder never removes data from the Mac.

import Foundation

/// What a package holds.
enum SyncKind: String, Codable {
    /// A pose session (one or two animals): session.json + pose.mpt.
    case poseSession
    /// A classic-centroid result (RodentFlow method): result.json + tracking.json + setup.json.
    case centroidResult
    /// A multi-chamber tail suspension recording: one record per chamber / animal.
    case tstRecording
}

/// Who the animal is and which session this was (as the Mac's task / group / animal / session tree needs it).
struct SyncSubject: Codable, Equatable {
    var animalID: String = ""
    var group: String = ""
    /// "", "M" or "F".
    var sex: String = ""
    /// Stored phase key (English for preset phases).
    var phase: String = ""
    var day: Int?
    var trial: Int?
    var notes: String = ""
    /// Recording date, "yyyy-MM-dd" (calendar day; never shifts with time zones).
    var sessionDate: String?
    /// The n-th session of this animal in this task, when the phone knows it.
    var sessionNumber: Int?
    var excluded = false
    var exclusionReason = ""

    init() {}

    enum CodingKeys: String, CodingKey {
        case animalID, group, sex, phase, day, trial, notes, sessionDate, sessionNumber, excluded, exclusionReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        animalID = c.v(.animalID, "")
        group = c.v(.group, "")
        sex = c.v(.sex, "")
        phase = c.v(.phase, "")
        day = c.v(.day, nil as Int?)
        trial = c.v(.trial, nil as Int?)
        notes = c.v(.notes, "")
        sessionDate = c.v(.sessionDate, nil as String?)
        sessionNumber = c.v(.sessionNumber, nil as Int?)
        excluded = c.v(.excluded, false)
        exclusionReason = c.v(.exclusionReason, "")
    }
}

/// One animal in a package (TST recordings hold one per chamber).
struct SyncRecord: Codable {
    /// Stable identity of the animal's session on the phone (session id; TST: derived from recording + chamber).
    var recordID: UUID
    var subject: SyncSubject
    /// TST: chamber number (1-based).
    var chamber: Int?
    /// The phone's own numbers for this animal (what the phone's result screen showed).
    var summary: SessionMetricSummary?
}

struct SyncFileInfo: Codable, Equatable {
    var size: Int64
    /// FNV-1a 64-bit of the file contents (hex); empty for large files (size only).
    var checksum: String
}

struct SyncManifest: Codable {
    static let currentFormat = 1
    static let fileName = "manifest.json"

    var format = SyncManifest.currentFormat
    var kind: SyncKind
    /// Stable identity of the package (the phone's session / result / recording id).
    var packageID: UUID
    /// Last change of the source on the phone; a newer revision replaces the Mac's earlier import.
    var revision: Date
    var createdAt: Date
    /// StudyAssay raw value.
    var assay: String
    var method: TrackingMethod
    /// e.g. "RodentFlow 2.0 (1) · iOS".
    var app: String
    var device: String
    var deviceID: String
    var videoName: String = ""
    var videoDuration: Double = 0
    var videoFPS: Double = 0
    var videoWidth: Double = 0
    var videoHeight: Double = 0
    /// File name of the included video copy (nil = the video stays on the phone).
    var videoFile: String?
    /// Calibration frame (JPEG) for figures and review on the Mac.
    var frameFile: String?
    /// Pose model of the keypoints.
    var model: String?
    var records: [SyncRecord]
    /// Every file of the package except the manifest.
    var files: [String: SyncFileInfo] = [:]

    var studyAssay: StudyAssay? { StudyAssay(rawValue: assay) }
}

enum SyncPackage {
    static let rootFolderName = "RodentFlow Sync"
    static let packageExtension = "rfsession"
    /// Files larger than this are checked by size only (videos).
    static let checksumLimit: Int64 = 64 * 1024 * 1024

    enum Status: Equatable {
        case ready
        /// Some files are missing or still downloading / syncing; try again later.
        case incomplete(String)
        /// Sizes or checksums do not match the manifest, or the manifest cannot be read.
        case damaged(String)
        /// Written by a newer app version.
        case unsupported(Int)
    }

    static func folderName(_ id: UUID) -> String { id.uuidString + "." + packageExtension }

    /// Folder of this device inside the chosen sync folder (created when missing).
    static func deviceFolder(in chosen: URL, deviceName: String, deviceID: String) throws -> URL {
        let safe = deviceName.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" ? String($0) : "_" }.joined()
        let name = (safe.trimmingCharacters(in: .whitespaces).isEmpty ? "iPhone" : safe) + " (" + String(deviceID.prefix(8)) + ")"
        let url = chosen.appendingPathComponent(rootFolderName, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let readme = chosen.appendingPathComponent(rootFolderName).appendingPathComponent("README.txt")
        if !FileManager.default.fileExists(atPath: readme.path) {
            let text = """
            RodentFlow sync folder

            Each *.rfsession folder is one analysis made on an iPhone or iPad. RodentFlow on the Mac imports
            them automatically when this folder (or the folder containing it) is chosen in
            RodentFlow › Settings › Phone data. Imported data is copied into the Mac app; deleting packages here
            does not delete anything on the Mac or on the phone.
            """
            try? Data(text.utf8).write(to: readme, options: .atomic)
        }
        return url
    }

    // MARK: Writing

    /// A file to put into a package: copied from `source` or written from `data`.
    struct Item {
        var name: String
        var source: URL?
        var data: Data?

        static func file(_ name: String, _ url: URL) -> Item { Item(name: name, source: url, data: nil) }
        static func data(_ name: String, _ data: Data) -> Item { Item(name: name, source: nil, data: data) }
    }

    /// Writes a package atomically into `folder` (the device folder) and returns its URL. An earlier
    /// package with the same id is replaced only after the new one is complete.
    @discardableResult
    static func write(_ manifest: SyncManifest, items: [Item], into folder: URL) throws -> URL {
        let fm = FileManager.default
        let final = folder.appendingPathComponent(folderName(manifest.packageID), isDirectory: true)
        let temp = folder.appendingPathComponent("." + folderName(manifest.packageID) + ".partial-" + UUID().uuidString.prefix(8), isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        do {
            var m = manifest
            m.files = [:]
            for item in items {
                let dst = temp.appendingPathComponent(item.name)
                if let src = item.source {
                    try fm.copyItem(at: src, to: dst)
                } else if let data = item.data {
                    try data.write(to: dst, options: .atomic)
                } else {
                    continue
                }
                m.files[item.name] = try fileInfo(dst)
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            // The manifest is written last: a package without one is never read.
            try enc.encode(m).write(to: temp.appendingPathComponent(SyncManifest.fileName), options: .atomic)
            if fm.fileExists(atPath: final.path) {
                let old = folder.appendingPathComponent("." + folderName(manifest.packageID) + ".old-" + UUID().uuidString.prefix(8), isDirectory: true)
                try fm.moveItem(at: final, to: old)
                try fm.moveItem(at: temp, to: final)
                try? fm.removeItem(at: old)
            } else {
                try fm.moveItem(at: temp, to: final)
            }
            return final
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    static func fileInfo(_ url: URL) throws -> SyncFileInfo {
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return SyncFileInfo(size: size, checksum: size <= checksumLimit ? try checksum(url) : "")
    }

    // MARK: Reading

    static func readManifest(_ package: URL) throws -> SyncManifest {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(SyncManifest.self, from: Data(contentsOf: package.appendingPathComponent(SyncManifest.fileName)))
    }

    /// Whether a package can be imported now. Checks every file against the manifest.
    static func check(_ package: URL) -> (SyncManifest?, Status) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: package.appendingPathComponent(SyncManifest.fileName).path) else {
            return (nil, .incomplete("manifest.json"))
        }
        let manifest: SyncManifest
        do {
            manifest = try readManifest(package)
        } catch {
            return (nil, .damaged(error.localizedDescription))
        }
        guard manifest.format <= SyncManifest.currentFormat else { return (manifest, .unsupported(manifest.format)) }
        for (name, info) in manifest.files.sorted(by: { $0.key < $1.key }) {
            let url = package.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return (manifest, .incomplete(name)) }
            guard let actual = try? fileInfo(url) else { return (manifest, .incomplete(name)) }
            if actual.size < info.size { return (manifest, .incomplete(name)) }
            if actual.size != info.size { return (manifest, .damaged(name)) }
            if !info.checksum.isEmpty && actual.checksum != info.checksum { return (manifest, .damaged(name)) }
        }
        return (manifest, .ready)
    }

    /// Package folders under `root` (the chosen folder, its "RodentFlow Sync" folder or a device
    /// folder), at most four levels deep; temporary folders are skipped.
    static func scan(_ root: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        func visit(_ dir: URL, depth: Int) {
            guard depth <= 4, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: [.skipsHiddenFiles]) else { return }
            for url in items {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if url.pathExtension == packageExtension {
                    out.append(url)
                } else {
                    visit(url, depth: depth + 1)
                }
            }
        }
        if root.pathExtension == packageExtension { return [root] }
        visit(root, depth: 0)
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Checksum

    /// FNV-1a 64-bit over the file, read in 1 MB blocks.
    static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { raw in
                for b in raw.bindMemory(to: UInt8.self) {
                    hash ^= UInt64(b)
                    hash = hash &* 0x0000_0100_0000_01B3
                }
            }
        }
        return String(format: "%016llx", hash)
    }

    // MARK: Dates

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Calendar day of a recording, "yyyy-MM-dd".
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
}

// MARK: - Consistency check

/// Phone numbers vs. the Mac's recomputation of the same session.
struct SyncComparison: Equatable {
    struct Difference: Equatable {
        var key: String
        var name: String
        var phone: Double?
        var mac: Double?
    }

    var compared = 0
    var differences: [Difference] = []
    /// The phone's numbers were computed with older measure definitions than this app's (a package written by
    /// RodentFlow 2.1 build 22 or earlier: the phone refreshes stored numbers without re-sending them).
    var phoneDefinitionsOlder = false

    var isConsistent: Bool { compared > 0 && differences.isEmpty }

    /// Compares every measure both sides have. Values agree when they are equal after rounding to the
    /// measure's displayed decimals (plus one), or within 1e-6 relative.
    static func compare(phone: SessionMetricSummary, mac: SessionMetricSummary) -> SyncComparison {
        var out = SyncComparison()
        out.phoneDefinitionsOlder = (phone.definitions ?? 1) < SessionMetricSummary.currentDefinitions
        let macValues = mac.values
        for e in phone.metrics {
            let p = e.value, m = macValues[e.key]
            if p == nil && m == nil { continue }
            out.compared += 1
            guard let p, let m else {
                out.differences.append(Difference(key: e.key, name: e.nameEN, phone: p, mac: m))
                continue
            }
            let scale = pow(10.0, Double(max(0, e.decimals) + 1))
            let same = (p * scale).rounded() == (m * scale).rounded() || abs(p - m) <= 1e-6 * max(1, abs(p), abs(m))
            if !same { out.differences.append(Difference(key: e.key, name: e.nameEN, phone: p, mac: m)) }
        }
        return out
    }
}
