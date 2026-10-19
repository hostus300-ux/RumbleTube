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

    static let historyLimit = 500

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

    mutating func savePosition(_ id: String, _ t: Double) {
        positions[id] = t
        if positions.count > 2000 {
            let keep = Set(history.prefix(1000).map(\.id))
            positions = positions.filter { keep.contains($0.key) }
        }
    }
}
