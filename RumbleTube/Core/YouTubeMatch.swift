import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Finds the YouTube upload of a Rumble video (so SponsorBlock segments can be used),
/// by searching YouTube for the title and checking title, channel and length.
struct YouTubeCandidate: Equatable {
    var videoID: String
    var title: String
    var channel: String
    var duration: Double?
}

enum MatchConfidence: String, Codable, Comparable {
    /// none: not found. differentEdit: same video identity but lengths differ a lot (times won't line up).
    /// likely: lengths within ~30s → show skip buttons. exact: lengths within 3s → auto-skip.
    case none, differentEdit, likely, exact
    static func < (a: Self, b: Self) -> Bool { a.order < b.order }
    private var order: Int { [.none: 0, .differentEdit: 1, .likely: 2, .exact: 3][self] ?? 0 }
    var usable: Bool { self == .likely || self == .exact }
}

struct YouTubeMatch: Equatable {
    var candidate: YouTubeCandidate
    var confidence: MatchConfidence
    var titleScore: Double
    var channelScore: Double
    var durationDiff: Double?
}

/// Cached result for one Rumble video.
struct AutoLinkRecord: Codable, Equatable {
    var youtubeID: String?
    var youtubeTitle: String?
    var youtubeChannel: String?
    var confidence: MatchConfidence
    /// Rumble length minus YouTube length (seconds); positive = Rumble is longer.
    var lengthDifference: Double?
    var checkedAt: Date
    var rejected: Bool = false

    static func from(_ m: YouTubeMatch?, rumbleDuration: Double?, at date: Date = Date()) -> AutoLinkRecord {
        guard let m else { return AutoLinkRecord(confidence: .none, checkedAt: date) }
        let diff = (rumbleDuration != nil && m.candidate.duration != nil) ? rumbleDuration! - m.candidate.duration! : nil
        return AutoLinkRecord(youtubeID: m.candidate.videoID, youtubeTitle: m.candidate.title, youtubeChannel: m.candidate.channel,
                              confidence: m.confidence, lengthDifference: diff, checkedAt: date)
    }

    /// Re-search misses after a few days (the YouTube upload may appear later); keep hits.
    func isFresh(now: Date = Date()) -> Bool {
        confidence != .none || now.timeIntervalSince(checkedAt) < 3 * 86400
    }
}

enum YouTubeMatcher {
    // MARK: search request + parsing

    static func searchRequest(_ query: String) -> URLRequest {
        // sp=EgIQAQ== → "Videos" filter. Encode strictly (some characters trip up URL loading otherwise).
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var r = URLRequest(url: URL(string: "https://www.youtube.com/results?search_query=\(q)&sp=EgIQAQ%3D%3D")!)
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36",
                   forHTTPHeaderField: "User-Agent")
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.setValue("SOCS=CAI; CONSENT=YES+1", forHTTPHeaderField: "Cookie")   // skip the EU consent page
        r.httpShouldHandleCookies = false
        r.timeoutInterval = 12
        return r
    }

    static func query(title: String, channel: String?) -> String {
        var q = cleanForQuery(title)
        if let ch = channel.map(cleanChannel), !ch.isEmpty, !normalize(q).contains(normalize(ch)) { q += " " + ch }
        return String(q.prefix(120))
    }

    /// Pulls videoRenderer entries out of the ytInitialData blob on a YouTube results page.
    static func parseSearch(_ html: String) -> [YouTubeCandidate] {
        guard let start = html.range(of: "ytInitialData = ") ?? html.range(of: "ytInitialData\"] = "),
              let end = html.range(of: ";</script>", range: start.upperBound..<html.endIndex),
              let data = String(html[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [YouTubeCandidate] = []
        func walk(_ o: Any) {
            if let d = o as? [String: Any] {
                if let v = d["videoRenderer"] as? [String: Any], let c = candidate(v) { out.append(c) }
                for (k, x) in d where k != "videoRenderer" { walk(x) }
            } else if let a = o as? [Any] {
                a.forEach(walk)
            }
        }
        walk(json)
        var seen = Set<String>()
        return out.filter { seen.insert($0.videoID).inserted }
    }

    private static func candidate(_ v: [String: Any]) -> YouTubeCandidate? {
        guard let id = v["videoId"] as? String else { return nil }
        let title = runsText(v["title"]) ?? ""
        let channel = runsText(v["ownerText"]) ?? runsText(v["longBylineText"]) ?? ""
        let length = (v["lengthText"] as? [String: Any])?["simpleText"] as? String
        return YouTubeCandidate(videoID: id, title: title, channel: channel, duration: length.flatMap(TimeFormat.parseClock))
    }

    private static func runsText(_ v: Any?) -> String? {
        guard let d = v as? [String: Any] else { return nil }
        if let s = d["simpleText"] as? String { return s }
        return (d["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
    }

    // MARK: scoring

    /// Best match among candidates, or nil when nothing is convincing.
    static func bestMatch(title: String, channel: String?, duration: Double?, candidates: [YouTubeCandidate]) -> YouTubeMatch? {
        let scored = candidates.map { c -> YouTubeMatch in
            let ts = titleSimilarity(title, c.title)
            let cs = channel.map { channelSimilarity($0, c.channel) } ?? 0
            let diff = (duration != nil && c.duration != nil) ? abs(duration! - c.duration!) : nil
            return YouTubeMatch(candidate: c, confidence: confidence(ts, cs, diff, duration), titleScore: ts,
                                channelScore: cs, durationDiff: diff)
        }
        return scored.filter { $0.confidence != .none }.max { a, b in
            a.confidence != b.confidence ? a.confidence < b.confidence : score(a) < score(b)
        }
    }

    static func confidence(_ ts: Double, _ cs: Double, _ diff: Double?, _ duration: Double?) -> MatchConfidence {
        guard let diff else { return .none }   // never match without comparing lengths
        let tight = diff <= 3
        let loose = diff <= 15
        let sameVideo = (ts >= 0.7 && cs >= 0.75) || (ts >= 0.9 && cs >= 0.5)
        if tight && (sameVideo || ts >= 0.9) { return .exact }
        if loose && ts >= 0.6 && cs >= 0.75 { return .likely }
        if sameVideo { return .differentEdit }
        return .none
    }

    private static func score(_ m: YouTubeMatch) -> Double {
        let d = m.durationDiff.map { 1 - min($0 / 60, 1) } ?? 0
        return m.titleScore * 0.5 + m.channelScore * 0.3 + d * 0.2
    }

    // MARK: text helpers

    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = Double(ta.intersection(tb).count)
        let dice = 2 * inter / Double(ta.count + tb.count)
        let containment = inter / Double(min(ta.count, tb.count))
        // Titles often differ only by a channel suffix ("… | Timcast IRL") or an episode tag.
        return max(dice, containment * 0.92)
    }

    static func channelSimilarity(_ a: String, _ b: String) -> Double {
        let na = normalize(cleanChannel(a)).replacingOccurrences(of: " ", with: "")
        let nb = normalize(cleanChannel(b)).replacingOccurrences(of: " ", with: "")
        guard !na.isEmpty, !nb.isEmpty else { return 0 }
        if na == nb { return 1 }
        if na.contains(nb) || nb.contains(na) { return 0.9 }
        let ta = tokens(cleanChannel(a)), tb = tokens(cleanChannel(b))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return 2 * Double(ta.intersection(tb).count) / Double(ta.count + tb.count)
    }

    /// "TimcastIRLVerified" / "@MurTechVerified" → "TimcastIRL" / "MurTech"
    static func cleanChannel(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("Verified") { t = String(t.dropLast("Verified".count)) }
        if t.hasPrefix("@") { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static let stopwords: Set<String> = ["the", "a", "an", "and", "of", "to", "in", "on", "with", "w", "for", "is", "at", "by", "ep", "episode", "live", "full"]

    static func tokens(_ s: String) -> Set<String> {
        Set(normalize(s).split(separator: " ").map(String.init).filter { !stopwords.contains($0) && !$0.isEmpty })
    }

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en_US"))
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "&", with: " and ")
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    private static func cleanForQuery(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { !$0.properties.isEmojiPresentation && !($0.properties.isEmoji && $0.value > 0x2000) }
        return String(String.UnicodeScalarView(scalars)).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
