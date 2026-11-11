// SessionDate.swift — recording dates as calendar days ("yyyy-MM-dd"), shared by the phone and the Mac.
import Foundation

/// Recording dates are stored as calendar days ("yyyy-MM-dd"), so they never shift with time zones.
enum SessionDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }

    static func date(_ text: String?) -> Date? {
        guard let text, text.count == 10 else { return nil }
        return formatter.date(from: text)
    }

    static func isValid(_ text: String?) -> Bool { date(text) != nil }

    /// A date written in a file name: 2026-10-17, 2026_10_17, 2026.10.17 or 20261017 (years 1990–2099).
    static func fromFileName(_ name: String) -> String? {
        let patterns = [#"(19|20)\d{2}[-_.](0[1-9]|1[0-2])[-_.](0[1-9]|[12]\d|3[01])"#,
                         #"(19|20)\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)),
                  let range = Range(match.range, in: name) else { continue }
            let digits = name[range].filter { $0.isNumber }
            guard digits.count == 8 else { continue }
            let s = String(digits)
            let year = String(s.prefix(4))
            let month = String(s.dropFirst(4).prefix(2))
            let day = String(s.suffix(2))
            let text = year + "-" + month + "-" + day
            if isValid(text) { return text }
        }
        return nil
    }
}
