// ABISupport.swift — plumbing shared by the C ABI entry points: string ownership, the handle
// table, and JSON helpers. No science here; see TrackingRun.swift and AnalysisRun.swift.
//
// String ownership: every `char *` this library returns was allocated by `rfMakeCString` and must
// be released with `rf_string_free`. Memory is allocated and freed on the Swift side only, so the
// two runtimes never free each other's blocks.

import Foundation

// MARK: - Strings across the boundary

/// A NUL-terminated UTF-8 copy of `s`, owned by the caller until `rf_string_free`.
func rfMakeCString(_ s: String) -> UnsafeMutablePointer<CChar> {
    let bytes = Array(s.utf8)
    let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
    p[bytes.count] = 0
    return p
}

/// Swift string from a C string; nil when the pointer is nil.
func rfReadCString(_ p: UnsafePointer<CChar>?) -> String? {
    guard let p else { return nil }
    return String(cString: p)
}

// MARK: - JSON

enum RFJSON {
    static func encode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"Cannot encode the result as JSON\"}"
        }
        return text
    }

    static func object(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else {
            throw RFError.badArgument("Expected a JSON object")
        }
        return dict
    }

    /// `ok: true` plus the given fields.
    static func ok(_ fields: [String: Any] = [:]) -> String {
        var d = fields
        d["ok"] = true
        return encode(d)
    }

    static func failure(_ message: String) -> String {
        encode(["ok": false, "error": message])
    }

    /// A JSON number that survives JSONSerialization (NaN and infinity are not valid JSON).
    static func number(_ v: Double) -> Any { v.isFinite ? v : NSNull() }
    static func number(_ v: Float) -> Any { v.isFinite ? Double(v) : NSNull() }
}

enum RFError: LocalizedError {
    case badArgument(String)
    case badHandle
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .badArgument(let m): return m
        case .badHandle: return "Unknown run handle (already closed?)"
        case .failed(let m): return m
        }
    }
}

// MARK: - Codable over the boundary

enum RFCoding {
    /// The engine's own date strategy: `Session`, `InferenceSettings` and `PoseStreamManifest` all use
    /// the default (exact) encoding, as the apps do, so a file written here reads back identically.
    ///
    /// Non-finite numbers are read as the Mac's files write them ("nan", "inf", "-inf"; MarbleSampler's
    /// marble_samples.json), so marble readings with a marble partly outside the frame can be sent as they are.
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        // A non-finite number is written as the Mac's files write it, instead of failing the whole reply
        // (a session summary's series can hold NaN); the decoder above reads it back.
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else { throw RFError.badArgument("Argument is not UTF-8") }
        return try decoder().decode(type, from: data)
    }
}

// MARK: - Handle table

/// Live tracking runs, addressed by a small integer so the host language never holds a Swift pointer.
final class RFRunTable {
    static let shared = RFRunTable()
    private let lock = NSLock()
    private var runs: [Int32: TrackingRun] = [:]
    private var next: Int32 = 1

    func insert(_ run: TrackingRun) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        let h = next
        next += 1
        runs[h] = run
        return h
    }

    func get(_ handle: Int32) -> TrackingRun? {
        lock.lock(); defer { lock.unlock() }
        return runs[handle]
    }

    func remove(_ handle: Int32) -> TrackingRun? {
        lock.lock(); defer { lock.unlock() }
        return runs.removeValue(forKey: handle)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return runs.count
    }
}

// MARK: - Status codes (keep in step with rodentflow.h and RodentFlowNative.cs)

enum RFStatus: Int32 {
    /// Run the model on this frame / the frame was accepted.
    case analyze = 1
    /// Skip this frame (stride) — nothing was written.
    case skip = 0
    /// Before the analysed range: keep decoding.
    case beforeRange = -1
    /// Past the analysed range: stop decoding.
    case pastRange = -2
    case badHandle = -10
    case badArgument = -11
    case writeFailed = -12
    /// Too many failed frames in a row (the rows written so far are kept).
    case tooManyFailures = -13
}
