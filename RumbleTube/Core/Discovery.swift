import Foundation

// Discover ranking: Trending (videos + live) and For You, computed on the phone.
// Rumble supplies raw numbers only (views, votes, comments, upload time, live viewers, chat);
// all ranking happens here so it can be unit-tested and later swapped for a server list.

struct RankedVideo: Identifiable, Hashable {
    var item: VideoItem
    var score: Double
    /// Short label shown on the card, e.g. "↑ 4.1K views/hr" or "Because you watch TimcastIRL".
    var reason: String?
    var id: String { item.id }
}

/// Last seen view count per video, kept between Discover visits so v1 gets real views/hour
/// when the same video shows up again later.
struct ViewSnapshot: Codable, Hashable {
    var views: Int
    var at: Date
}

// MARK: - Trending

enum TrendingRanker {
    static let window: TimeInterval = 7 * 86_400
    static let decayHours = 72.0

    /// Views gained per hour: from an earlier snapshot ≥ 1 h old when we have one, else lifetime average.
    static func velocity(_ v: VideoItem, now: Date, previous: ViewSnapshot?) -> (perHour: Double, measured: Bool)? {
        guard let views = v.viewCount, let up = v.publishedDate else { return nil }
        if let p = previous, now.timeIntervalSince(p.at) >= 3600, views >= p.views {
            return (Double(views - p.views) / (now.timeIntervalSince(p.at) / 3600), true)
        }
        return (Double(views) / max(now.timeIntervalSince(up) / 3600, 1), false)
    }

    static func engagement(_ v: VideoItem) -> Double {
        let likes = Double(v.likes ?? 0), dislikes = Double(v.dislikes ?? 0), comments = Double(v.commentCount ?? 0)
        let e = (likes - 0.5 * dislikes + 3 * comments) / Double(max(v.viewCount ?? 0, 50))
        return min(max(e, 0), 0.25)   // cap so tiny videos with a few likes can't top the list
    }

    /// On-demand videos from the last 7 days, best first. Unscored videos are appended newest-first.
    static func videos(_ items: [VideoItem], now: Date = Date(), previous: [String: ViewSnapshot] = [:],
                       minimum: Int = 20) -> [RankedVideo] {
        let fresh = unique(items).filter { v in
            !v.isLive && v.upcoming != true && v.isShort != true &&
            (v.publishedDate.map { now.timeIntervalSince($0) <= window && now.timeIntervalSince($0) >= 0 } ?? false)
        }
        var scored: [RankedVideo] = []
        var unscored: [VideoItem] = []
        for v in fresh {
            guard let vel = velocity(v, now: now, previous: previous[v.id]), let up = v.publishedDate else { unscored.append(v); continue }
            let ageH = now.timeIntervalSince(up) / 3600
            let quality = log(1 + vel.perHour) + 0.6 * log(1 + 1000 * engagement(v))
            let score = quality * exp(-ageH / decayHours)
            let reason = vel.perHour >= 10 ? "↑ \(CountFormat.short(Int(vel.perHour))) views/hr" : nil
            scored.append(RankedVideo(item: v, score: score, reason: reason))
        }
        scored.sort { $0.score > $1.score }
        var out = diversify(scored)
        if out.count < minimum {
            let have = Set(out.map(\.id))
            out += unscored.filter { !have.contains($0.id) }
                .sorted { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
                .map { RankedVideo(item: $0, score: 0, reason: nil) }
        }
        return out
    }

    /// Live streams by viewers and chat speed (messages/min; optional).
    static func live(_ items: [VideoItem], chatPerMinute: [String: Double] = [:]) -> [RankedVideo] {
        unique(items).filter(\.isLive).map { v in
            let viewers = Double(v.watching ?? 0)
            let chat = chatPerMinute[v.id] ?? 0
            let score = log(1 + viewers) + 0.8 * log(1 + chat)
            let reason = chat >= 1 ? "\(Int(chat.rounded())) chats/min" : nil
            return RankedVideo(item: v, score: score, reason: reason)
        }
        .sorted { $0.score > $1.score }
    }

    /// Newest first (secondary sort / "Newest" filter).
    static func newest(_ items: [VideoItem], live: Bool) -> [RankedVideo] {
        unique(items).filter { live ? $0.isLive : (!$0.isLive && $0.upcoming != true && $0.isShort != true) }
            .sorted { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
            .map { RankedVideo(item: $0, score: 0, reason: nil) }
    }

    static func unique(_ items: [VideoItem]) -> [VideoItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// At most `perChannel` videos from one channel in any `window` consecutive results.
    static func diversify(_ list: [RankedVideo], perChannel: Int = 2, window: Int = 10) -> [RankedVideo] {
        var out: [RankedVideo] = []
        var held: [RankedVideo] = []
        for r in list {
            if fits(r, out, perChannel, window) { out.append(r) } else { held.append(r) }
            // release held items as soon as they fit again
            var i = 0
            while i < held.count {
                if fits(held[i], out, perChannel, window) { out.append(held.remove(at: i)) } else { i += 1 }
            }
        }
        return out + held
    }

    private static func fits(_ r: RankedVideo, _ out: [RankedVideo], _ per: Int, _ window: Int) -> Bool {
        guard let c = r.item.channelPath?.lowercased() else { return true }
        return out.suffix(window - 1).filter { $0.item.channelPath?.lowercased() == c }.count < per
    }
}

// MARK: - For You (personal, on-device)

struct TasteProfile: Equatable {
    var channels: [String: Double] = [:]      // channel path (lowercased) → 0…1
    var channelNames: [String: String] = [:]
    var categories: [String: Double] = [:]
    var keywords: [String: Double] = [:]
    var watchedCount = 0

    var isCold: Bool { watchedCount < 5 }

    /// Channels you like most, best first.
    var topChannels: [String] { channels.sorted { $0.value > $1.value }.map(\.key) }
    var topKeywords: [String] { keywords.sorted { $0.value > $1.value }.map(\.key) }
    var topCategories: [String] { categories.sorted { $0.value > $1.value }.map(\.key) }

    /// - history: watched videos with when; completion: 0…1 for a video id; follows: followed channel paths.
    static func build(history: [(video: VideoItem, at: Date)], completion: (VideoItem) -> Double?,
                      follows: [ChannelRef], now: Date = Date(), halfLifeDays: Double = 14) -> TasteProfile {
        var p = TasteProfile()
        var docFreq: [String: Int] = [:]
        var termWeight: [String: Double] = [:]
        for h in history where h.video.isShort != true {
            let days = max(0, now.timeIntervalSince(h.at) / 86_400)
            let done = min(1, max(0.15, completion(h.video) ?? 0.3))       // opened but unknown → small weight
            let w = done * pow(0.5, days / halfLifeDays)
            if let c = h.video.channelPath?.lowercased() {
                p.channels[c, default: 0] += w
                p.channelNames[c] = h.video.channelName ?? p.channelNames[c]
            }
            if let k = h.video.category { p.categories[k, default: 0] += w }
            for t in Set(tokens(h.video.title)) {
                docFreq[t, default: 0] += 1
                termWeight[t, default: 0] += w
            }
            p.watchedCount += 1
        }
        for f in follows { p.channels[f.id, default: 0] += 3; p.channelNames[f.id] = f.name }
        let n = Double(max(p.watchedCount, 1))
        for (t, w) in termWeight where docFreq[t, default: 0] >= 2 {      // a word seen once says little
            p.keywords[t] = w * log(1 + n / Double(docFreq[t]!))
        }
        p.channels = normalised(p.channels, keep: 20)
        p.categories = normalised(p.categories, keep: 8)
        p.keywords = normalised(p.keywords, keep: 30)
        return p
    }

    func keywordSimilarity(_ title: String) -> Double {
        let ts = Set(TasteProfile.tokens(title))
        guard !ts.isEmpty, !keywords.isEmpty else { return 0 }
        let hit = ts.reduce(0.0) { $0 + (keywords[$1] ?? 0) }
        return min(1, hit / sqrt(Double(ts.count)))
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) && Int($0) == nil }
    }

    private static func normalised(_ d: [String: Double], keep: Int) -> [String: Double] {
        let top = d.sorted { $0.value > $1.value }.prefix(keep)
        guard let m = top.first?.value, m > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value / m) })
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "you", "your", "with", "this", "that", "are", "was", "what", "how", "why", "who",
        "from", "they", "their", "has", "have", "had", "not", "but", "all", "can", "will", "just", "about",
        "out", "now", "new", "full", "episode", "live", "show", "video", "watch", "today", "news", "ep",
        "his", "her", "him", "she", "its", "our", "into", "more", "than", "when", "over", "after", "says",
    ]
}

enum ForYouRanker {
    /// Rank candidates against the profile. `watchedFraction` hides things you've finished.
    static func rank(_ items: [VideoItem], profile: TasteProfile, live: Bool,
                     trending: [String: Double] = [:], watchedFraction: (VideoItem) -> Double? = { _ in nil }) -> [RankedVideo] {
        let maxTrend = trending.values.max() ?? 0
        let pool = TrendingRanker.unique(items).filter { v in
            v.isShort != true && v.upcoming != true && (live ? v.isLive : !v.isLive) && (watchedFraction(v) ?? 0) < 0.9
        }
        let ranked: [RankedVideo] = pool.map { v in
            let c = v.channelPath.map { profile.channels[$0.lowercased()] ?? 0 } ?? 0
            let k = v.category.map { profile.categories[$0] ?? 0 } ?? 0
            let kw = profile.keywordSimilarity(v.title)
            let t = maxTrend > 0 ? (trending[v.id] ?? 0) / maxTrend : 0
            var score = 0.45 * c + 0.25 * k + 0.20 * kw + 0.10 * t
            if live { score += 0.05 * log(1 + Double(v.watching ?? 0)) / 10 }
            var reason: String?
            if c >= 0.3, let name = v.channelName { reason = "Because you watch \(name)" }
            else if kw >= 0.35, let word = TasteProfile.tokens(v.title).max(by: { (profile.keywords[$0] ?? 0) < (profile.keywords[$1] ?? 0) }) {
                reason = "Because you like \(word.capitalized)"
            } else if k >= 0.4, let cat = v.category { reason = "More \(cat)" }
            return RankedVideo(item: v, score: score, reason: reason)
        }
        .filter { $0.score > 0.02 }
        .sorted { $0.score > $1.score }
        return TrendingRanker.diversify(ranked)
    }
}

// MARK: - Went-live alerts

enum LiveAlertTracker {
    /// Channels that are live now but weren't at the last check. `previous` holds channel ids.
    static func newlyLive(previous: Set<String>, current: [FollowedChannel]) -> [FollowedChannel] {
        current.filter { $0.isLive && !previous.contains($0.id) }
    }
    static func liveIDs(_ c: [FollowedChannel]) -> Set<String> { Set(c.filter(\.isLive).map(\.id)) }
}

// MARK: - Timestamps & chapters in descriptions and comments

struct Chapter: Hashable {
    var start: Double
    var title: String
}

enum Timestamps {
    private static let re = try! NSRegularExpression(pattern: #"(?<![\d:])(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?![\d:])"#)

    /// Every "1:23" / "01:02:03" in the text with its time in seconds.
    static func find(in text: String) -> [(range: Range<String.Index>, seconds: Double)] {
        let ns = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: ns).compactMap { m in
            guard let r = Range(m.range, in: text) else { return nil }
            func g(_ i: Int) -> Double? { Range(m.range(at: i), in: text).flatMap { Double(text[$0]) } }
            guard let mm = g(2), let ss = g(3), ss < 60 else { return nil }
            let hh = g(1) ?? 0
            if hh > 0 && mm >= 60 { return nil }
            return (r, hh * 3600 + mm * 60 + ss)
        }
    }

    /// Chapters: at least 3 lines that start (or end) with a timestamp, in increasing order.
    static func chapters(in description: String, duration: Double? = nil) -> [Chapter] {
        var out: [Chapter] = []
        for raw in description.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let hit = find(in: line).first else { continue }
            let atStart = line[..<hit.range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " -–•([")).isEmpty
            let atEnd = line[hit.range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " )]")).isEmpty
            guard atStart || atEnd else { continue }
            var title = atStart ? String(line[hit.range.upperBound...]) : String(line[..<hit.range.lowerBound])
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|•)]("))
            guard !title.isEmpty else { continue }
            if let d = duration, d > 0, hit.seconds >= d { continue }
            out.append(Chapter(start: hit.seconds, title: title))
        }
        guard out.count >= 3, zip(out, out.dropFirst()).allSatisfy({ $0.start < $1.start }) else { return [] }
        return out
    }

    static func current(_ chapters: [Chapter], at t: Double) -> Chapter? {
        chapters.last { $0.start <= t + 0.5 }
    }
}

// MARK: - Search suggestions

enum SearchSuggest {
    enum Item: Hashable { case recent(String), channel(ChannelRef) }

    /// While typing: matching past searches first, then matching channels you follow. Empty text: recent searches.
    static func items(for text: String, history: [String], channels: [ChannelRef], limit: Int = 8) -> [Item] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return history.prefix(limit).map(Item.recent) }
        let recent = history.filter { $0.lowercased().contains(q) && $0.lowercased() != q }
            .sorted { ($0.lowercased().hasPrefix(q) ? 0 : 1) < ($1.lowercased().hasPrefix(q) ? 0 : 1) }
            .prefix(5).map(Item.recent)
        var seen = Set<String>()
        let chans = channels.filter { c in
            (c.name.lowercased().contains(q) || c.path.lowercased().contains(q)) && seen.insert(c.id).inserted
        }
        .prefix(4).map(Item.channel)
        return Array((recent + chans).prefix(limit))
    }
}
