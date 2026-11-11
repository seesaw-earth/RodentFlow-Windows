// WindowsShims.swift — the handful of symbols each RodentFlow app defines for the shared engine.
//
// The iPhone / iPad app, the Mac app and `tools/test_support/TestShims.swift` each provide these;
// this is the Windows copy. Same surface as TestShims (Lang, L, RFText, AppInfo, FlowAssay), with
// two differences:
//   • `Lang.isChinese` is a stored flag the host app sets (rf_set_language) instead of an env var;
//   • AppInfo carries the Windows version and build.
//
// Nothing else is added here: every other symbol the engine needs comes from the copied `Shared/`
// sources or from Foundation.

import Foundation

/// Interface language. The engine reads this through `L10n` and `L(_:_:)`.
/// Set once before analysing (`rf_set_language`); not changed while a run is in progress.
enum Lang {
    static var isChinese = false
}

/// Two-language literal used throughout the engine.
func L(_ en: String, _ zh: String) -> String { Lang.isChinese ? zh : en }

/// Stored interface labels (classic "Minute", …) are passed through the engine's own dictionary;
/// on Windows, as in the test shim, they are returned unchanged.
enum RFText {
    static func tr(_ s: String) -> String { s }
}

enum AppInfo {
    static let name = "RodentFlow"
    /// Product version shared with the Mac and iOS apps.
    static var version: String { "2.1" }
    /// Windows build number. Raise it with every build you hand out.
    static var build: String { "1" }
    /// Written into exports (`Exporter.reportJSON` → "app").
    static var label: String { name + " " + version + " (Windows build " + build + ")" }
}

/// The ten RodentFlow video assays (iOS: RodentFlow 1.x AssayKind; macOS: FlowAssay).
/// Kept identical to the other platforms so classic centroid sessions read back the same.
enum FlowAssay: String, Codable, CaseIterable {
    case openField = "open_field"
    case elevatedPlusMaze = "elevated_plus_maze"
    case lightDark = "light_dark_box"
    case yMaze = "y_maze"
    case tMaze = "t_maze"
    case novelObject = "novel_object_recognition"
    case morrisWaterMaze = "morris_water_maze"
    case barnesMaze = "barnes_maze"
    case fearConditioning = "fear_conditioning"
    case placePreference = "conditioned_place_preference"

    var phases: [String] {
        switch self {
        case .novelObject: return ["Training", "Test"]
        case .morrisWaterMaze, .barnesMaze: return ["Acquisition", "Probe"]
        case .fearConditioning: return ["Training", "Context test", "Cue test"]
        case .placePreference: return ["Pre-test", "Conditioning", "Test"]
        default: return []
        }
    }
    var defaultPhase: String { phases.last ?? "" }
    var usesDays: Bool { [.morrisWaterMaze, .barnesMaze, .placePreference].contains(self) }
    var usesTrials: Bool { [.morrisWaterMaze, .barnesMaze, .tMaze].contains(self) }
    static func phaseTitle(_ phase: String) -> String { phase }
}
