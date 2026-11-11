// L10n.swift — localization of the pose-analysis texts, shared by the iPhone / iPad and Mac apps.
// The interface language is selectable inside each app (`Lang.isChinese`, defined per platform),
// while exported scientific labels and generated reports ALWAYS use English.
// EnglishTranslations.json (Chinese source → English) and L10nPatterns.json (interpolated texts) are
// kept in step with the iOS Localizable.xcstrings by iOS/RodentFlow-iOS/tools/update_english_translations.py
// (the Mac adds its own entries to the same files).

import Foundation

enum L10n {
    static let preferenceKey = "uiLanguage" // "system", "zh-Hans", "en"

    private struct Template: Decodable {
        let regex: String
        let translation: String
        let source: String
    }

    private struct Entry {
        let regex: NSRegularExpression
        let translation: String
    }

    private static let englishDictionary: [String: String] = {
        guard let url = Bundle.main.url(forResource: "EnglishTranslations", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let translations = try? JSONDecoder().decode([String: String].self, from: bytes)
        else { return [:] }
        return translations
    }()

    private static let dynamicEntries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "L10nPatterns", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let templates = try? JSONDecoder().decode([Template].self, from: bytes)
        else { return [] }
        // Most specific first (most fixed text): a short template such as "探索{0}" also matches every longer
        // sentence that starts with "探索". Equal lengths keep the file order.
        func fixedLength(_ source: String) -> Int {
            source.replacingOccurrences(of: "\\{[0-9]+\\}", with: "", options: .regularExpression).count
        }
        let ranked = templates.enumerated().map { (order: $0.offset, length: fixedLength($0.element.source), template: $0.element) }
            .sorted { $0.length != $1.length ? $0.length > $1.length : $0.order < $1.order }
        return ranked.compactMap { item in
            guard let regex = try? NSRegularExpression(pattern: item.template.regex) else { return nil }
            return Entry(regex: regex, translation: item.template.translation)
        }
    }()

    /// Set with `L10n.$rendersEnglish.withValue(true) { … }` while a figure is rendered into a file: the figure's
    /// interface texts come out in English whatever the interface language. Task-local, so the live interface and
    /// analyses running meanwhile are not affected (the interface language itself is never changed).
    @TaskLocal static var rendersEnglish: Bool = false

    /// Interface language of the app (each platform defines `Lang`).
    static var isChinese: Bool { !rendersEnglish && Lang.isChinese }

    /// Results of the regex fallback below. Interpolated interface strings ("约 120 帧…") miss the
    /// static dictionary and would otherwise run up to ~90 regular expressions on every redraw.
    private static let memoLock = NSLock()
    private static var memo: [String: String] = [:]

    // For visible UI text only. Rebuilding the root view on preference change
    // ensures pre-localized strings update without relaunching the app.
    static func tr(_ text: String) -> String {
        isChinese ? text : english(text)
    }

    /// Reverse catalog (English → Chinese source) for labels that were stored in English,
    /// e.g. the cached headline metric name shown in session lists. When several sources share
    /// one translation, the shortest (then lexicographically first) is used.
    private static let chineseByEnglish: [String: String] = {
        var out: [String: String] = [:]
        for (zh, en) in englishDictionary {
            if let current = out[en], (current.count, current) <= (zh.count, zh) { continue }
            out[en] = zh
        }
        return out
    }()

    /// Interface text for a label that is persisted in English (never used for exports).
    static func display(english text: String) -> String {
        guard isChinese, !text.isEmpty else { return text }
        return chineseByEnglish[text] ?? text
    }

    /// Chinese source of a text: Chinese text as is, a known English translation back to its source,
    /// anything else unchanged (task summaries store metric names in both languages).
    static func chinese(_ text: String) -> String {
        if hasHan(text) { return text }
        return chineseByEnglish[text] ?? text
    }

    // Export and persistence path: NEVER consult the user's interface language.
    static func english(_ text: String) -> String {
        if let v = englishDictionary[text] { return v }
        memoLock.lock()
        let hit = memo[text]
        memoLock.unlock()
        if let hit { return hit }
        let result = translateDynamic(text)
        memoLock.lock()
        if memo.count > 4000 { memo.removeAll(keepingCapacity: true) }
        memo[text] = result
        memoLock.unlock()
        return result
    }

    private static func translateDynamic(_ text: String) -> String {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for item in dynamicEntries {
            guard let match = item.regex.firstMatch(in: text, range: fullRange),
                  match.range == fullRange else { continue }
            var translation = item.translation
            for i in stride(from: match.numberOfRanges - 1, through: 1, by: -1) {
                guard let range = Range(match.range(at: i), in: text) else { continue }
                // Translate nested descriptions, e.g. "陌生鼠" within a sentence.
                let value = english(String(text[range]))
                translation = translation.replacingOccurrences(of: "{\(i - 1)}", with: value)
            }
            return translation
        }
        return text
    }

    static func hasHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) || (0xF900...0xFAFF).contains(Int($0.value)) }
    }

    // Key-based fallback guarantees machine-generated metric names in exported
    // files are English even if an older version had a missing translation.
    static func metricLabel(_ label: String, key: String) -> String {
        let candidate = english(label)
        if !hasHan(candidate) { return candidate }
        return key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // Cached headline values in historical session.json may include localized
    // unit suffixes. Their numbers must not be reformatted or translated.
    static func englishDisplay(_ text: String) -> String {
        var value = text
        for unit in ["圈/min", "圈", "次"] {
            value = value.replacingOccurrences(of: unit, with: english(unit))
        }
        return hasHan(value) ? "—" : value
    }

    // Do not silently put untranslated Chinese scientific prose into English reports.
    static func reportText(_ text: String) -> String {
        let candidate = english(text)
        if !hasHan(candidate) { return candidate }
        if let joined = englishBySentence(text) { return joined }
        return "[An English translation for this automatically generated description is unavailable.]"
    }

    /// English of a text made of several catalog sentences joined into one entry: each sentence (split after
    /// 。！？) is translated on its own, and a sentence that still fails is tried clause by clause (split after ；).
    /// nil when any piece stays untranslated.
    private static func englishBySentence(_ text: String) -> String? {
        let sentences = pieces(of: text, after: ["。", "！", "？"])
        var out: [String] = []
        for sentence in sentences {
            let en = english(sentence)
            if !hasHan(en) { out.append(en); continue }
            let clauses = pieces(of: sentence, after: ["；"])
            guard clauses.count > 1 else { return nil }
            let parts = clauses.map { english($0) }
            if parts.contains(where: { hasHan($0) }) { return nil }
            out += parts
        }
        return out.isEmpty ? nil : out.joined(separator: " ")
    }

    /// Splits after each delimiter (kept with its piece); pieces are trimmed and empty ones dropped.
    private static func pieces(of text: String, after delimiters: Set<Character>) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if delimiters.contains(ch) {
                out.append(current)
                current = ""
            }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
