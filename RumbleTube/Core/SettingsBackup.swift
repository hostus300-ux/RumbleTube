import Foundation

/// Everything you set up in RumbleTube that Rumble itself doesn't store, as one portable file.
/// Watch history, resume positions and search history stay on the phone (Rumble syncs history anyway).
struct SettingsBackup: Codable {
    static let fileExtension = "rumbletube"
    var format = 1
    var exportedAt = Date()
    var appVersion: String?
    var prefs: AppPreferences?
    var skip: SkipSettings?
    var preferredHeight: Int?
    var muted: [MutedEntry]?
    var localSegments: [String: [SkipSegment]]?
    var localLinks: [String: YouTubeLink]?
    var skipStats: SkipStats?
    var follows: [ChannelRef]?
    var watchLater: [VideoItem]?

    init(from lib: LibraryData, appVersion: String?) {
        self.appVersion = appVersion
        prefs = lib.prefs; skip = lib.skip; preferredHeight = lib.preferredHeight
        muted = lib.muted; localSegments = lib.localSegments; localLinks = lib.localLinks
        skipStats = lib.skipStats; follows = lib.follows; watchLater = lib.watchLater
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    static func decode(_ data: Data) throws -> SettingsBackup {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(SettingsBackup.self, from: data)
    }

    /// Settings are replaced; lists (muted, follows, Watch Later, your own skip segments) are merged.
    func apply(to lib: inout LibraryData) {
        if let prefs { lib.prefs = prefs }
        if let skip { lib.skip = skip }
        if let preferredHeight { lib.preferredHeight = preferredHeight }
        if let skipStats, skipStats.skips > lib.skipStats.skips { lib.skipStats = skipStats }
        for m in muted ?? [] {
            if let j = lib.muted.firstIndex(where: { $0.key == m.key }) { lib.muted[j].tag = m.tag } else { lib.muted.append(m) }
        }
        for (k, v) in localSegments ?? [:] {
            let have = Set((lib.localSegments[k] ?? []).map(\.uuid))
            lib.localSegments[k, default: []] += v.filter { !have.contains($0.uuid) }
        }
        for (k, v) in localLinks ?? [:] where lib.localLinks[k] == nil { lib.localLinks[k] = v }
        for f in follows ?? [] where !lib.follows.contains(where: { $0.id == f.id }) { lib.follows.append(f) }
        for v in watchLater ?? [] where !lib.watchLater.contains(where: { $0.id == v.id }) { lib.watchLater.append(v) }
    }

    var summary: String {
        var parts: [String] = []
        if prefs != nil { parts.append("settings") }
        if let m = muted, !m.isEmpty { parts.append("\(m.count) muted") }
        if let f = follows, !f.isEmpty { parts.append("\(f.count) phone follows") }
        if let w = watchLater, !w.isEmpty { parts.append("\(w.count) Watch Later") }
        let segs = localSegments?.values.reduce(0) { $0 + $1.count } ?? 0
        if segs > 0 { parts.append("\(segs) skip segments") }
        return parts.joined(separator: ", ")
    }
}
