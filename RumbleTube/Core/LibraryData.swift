import Foundation

struct HistoryEntry: Codable, Hashable, Identifiable {
    var video: VideoItem
    var watchedAt: Date
    var id: String { video.id }
}

struct SkipStats: Codable, Equatable {
    var skips: Int = 0
    var secondsSaved: Double = 0
}

/// Everything the app persists, as one Codable document.
struct LibraryData: Codable, Equatable {
    var follows: [ChannelRef] = []
    var watchLater: [VideoItem] = []
    var history: [HistoryEntry] = []
    var positions: [String: Double] = [:]
    var preferredHeight: Int? = nil
    var skip = SkipSettings()
    var localSegments: [String: [SkipSegment]] = [:]
    var localLinks: [String: YouTubeLink] = [:]
    var skipStats = SkipStats()
    var prefs = AppPreferences()
    var autoLinks: [String: AutoLinkRecord] = [:]

    static let historyLimit = 500

    init() {}

    // Tolerant decoding so new fields in updates never wipe the user's library.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        follows = (try? c.decodeIfPresent([ChannelRef].self, forKey: .follows)) ?? []
        watchLater = (try? c.decodeIfPresent([VideoItem].self, forKey: .watchLater)) ?? []
        history = (try? c.decodeIfPresent([HistoryEntry].self, forKey: .history)) ?? []
        positions = (try? c.decodeIfPresent([String: Double].self, forKey: .positions)) ?? [:]
        preferredHeight = try? c.decodeIfPresent(Int.self, forKey: .preferredHeight)
        skip = (try? c.decodeIfPresent(SkipSettings.self, forKey: .skip)) ?? SkipSettings()
        localSegments = (try? c.decodeIfPresent([String: [SkipSegment]].self, forKey: .localSegments)) ?? [:]
        localLinks = (try? c.decodeIfPresent([String: YouTubeLink].self, forKey: .localLinks)) ?? [:]
        skipStats = (try? c.decodeIfPresent(SkipStats.self, forKey: .skipStats)) ?? SkipStats()
        prefs = (try? c.decodeIfPresent(AppPreferences.self, forKey: .prefs)) ?? AppPreferences()
        autoLinks = (try? c.decodeIfPresent([String: AutoLinkRecord].self, forKey: .autoLinks)) ?? [:]
    }

    mutating func saveAutoLink(_ id: String, _ r: AutoLinkRecord) {
        autoLinks[id] = r
        if autoLinks.count > 3000 {   // keep the cache bounded: drop the oldest
            for k in autoLinks.sorted(by: { $0.value.checkedAt < $1.value.checkedAt }).prefix(500).map(\.key) { autoLinks[k] = nil }
        }
    }

    func isFollowing(_ path: String) -> Bool { follows.contains { $0.id == path.lowercased() } }

    mutating func toggleFollow(_ c: ChannelRef) {
        if let i = follows.firstIndex(where: { $0.id == c.id }) { follows.remove(at: i) }
        else { follows.append(c); follows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    }

    func inWatchLater(_ id: String) -> Bool { watchLater.contains { $0.id == id } }

    mutating func toggleWatchLater(_ v: VideoItem) {
        if let i = watchLater.firstIndex(where: { $0.id == v.id }) { watchLater.remove(at: i) }
        else { watchLater.insert(v, at: 0) }
    }

    mutating func recordWatch(_ v: VideoItem, at date: Date = Date()) {
        history.removeAll { $0.video.id == v.id }
        history.insert(HistoryEntry(video: v, watchedAt: date), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    /// Resume position; finished videos (last 15s / 97%) start over.
    func resumePosition(for id: String, duration: Double?) -> Double? {
        guard let p = positions[id], p > 5 else { return nil }
        if let d = duration, d > 0, p > d - 15 || p > d * 0.97 { return nil }
        return p
    }

    /// How far through a video you are (0…1), from this phone or Rumble's own watch progress.
    func watchFraction(for item: VideoItem) -> Double? {
        guard let d = item.durationSeconds, d > 0, !item.isLive else { return nil }
        let p = max(positions[item.id] ?? 0, item.progress ?? 0)
        guard p > 0 else { return nil }
        return min(1, (p > d - 15 && d > 60) ? 1 : p / d)
    }

    mutating func savePosition(_ id: String, _ t: Double) {
        positions[id] = t
        if positions.count > 2000 {
            let keep = Set(history.prefix(1000).map(\.id))
            positions = positions.filter { keep.contains($0.key) }
        }
    }
}
