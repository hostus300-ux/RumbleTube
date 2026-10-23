import Foundation

enum TimeFormat {
    /// "1:02:44" / "12:01" / "42" → seconds
    static func parseClock(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0.0) { $0 * 60 + $1! }
    }

    /// 3725 → "1:02:05", 65 → "1:05"
    static func clock(_ t: Double) -> String {
        guard t.isFinite else { return "--:--" }
        let total = Int(t.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Clock with tenths, for segment editing: 65.25 → "1:05.3"
    static func precise(_ t: Double) -> String {
        guard t.isFinite else { return "--:--" }
        let neg = t < 0
        let a = abs(t)
        let h = Int(a) / 3600, m = (Int(a) % 3600) / 60
        let s = a - Double(h * 3600 + m * 60)
        var ss = String(format: "%04.1f", s)
        if ss == "60.0" { ss = "59.9" }
        return (neg ? "-" : "") + (h > 0 ? String(format: "%d:%02d:", h, m) + ss : "\(m):" + ss)
    }

    /// ISO-8601 duration "PT1H2M3S" → 3723
    static func parseISODuration(_ s: String) -> Double? {
        guard s.hasPrefix("P") else { return nil }
        var total = 0.0, num = "", inTime = false
        for ch in s.dropFirst() {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber || ch == "." { num.append(ch); continue }
            guard let v = Double(num) else { return nil }
            switch (ch, inTime) {
            case ("D", false): total += v * 86400
            case ("H", true): total += v * 3600
            case ("M", true): total += v * 60
            case ("S", true): total += v
            default: return nil
            }
            num = ""
        }
        return num.isEmpty ? total : nil
    }
}

enum DateParsing {
    static func iso8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // "2026-10-16 14:24:34" style
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    static func relative(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        let units: [(Double, String)] = [(31_536_000, "year"), (2_592_000, "month"), (604_800, "week"),
                                          (86_400, "day"), (3_600, "hour"), (60, "minute")]
        for (len, name) in units where s >= len {
            let n = Int(s / len)
            return "\(n) \(name)\(n == 1 ? "" : "s") ago"
        }
        return "just now"
    }
}

enum CountFormat {
    /// "1.81K" → 1810, "2,345" → 2345
    static func parse(_ s: String) -> Int? {
        var t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "").uppercased()
        var mult = 1.0
        if let last = t.last, let m = ["K": 1e3, "M": 1e6, "B": 1e9][String(last)] { mult = m; t.removeLast() }
        guard let v = Double(t) else { return nil }
        return Int((v * mult).rounded())
    }

    static func short(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return trim(Double(n) / 1e9) + "B"
        case 1_000_000...: return trim(Double(n) / 1e6) + "M"
        case 1_000...: return trim(Double(n) / 1e3) + "K"
        default: return "\(n)"
        }
    }

    private static func trim(_ v: Double) -> String {
        let s = String(format: v < 10 ? "%.1f" : "%.0f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

enum HTMLText {
    /// Strip tags and decode common entities.
    static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"</p>\s*"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeEntities(s).replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#039;": "'",
                   "&apos;": "'", "&nbsp;": " ", "&#34;": "\""]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        // numeric entities
        while let r = out.range(of: #"&#(x?[0-9a-fA-F]+);"#, options: .regularExpression) {
            var code = String(out[r].dropFirst(2).dropLast())
            let hex = code.hasPrefix("x")
            if hex { code.removeFirst() }
            let scalar = UInt32(code, radix: hex ? 16 : 10).flatMap(Unicode.Scalar.init).map(String.init) ?? ""
            out.replaceSubrange(r, with: scalar)
        }
        return out
    }
}

extension Collection {
    /// nil instead of a crash when the index is out of range.
    subscript(safe i: Index) -> Element? { indices.contains(i) ? self[i] : nil }
}
