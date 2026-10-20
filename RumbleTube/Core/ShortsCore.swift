import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One short from rumble.com/service.php?name=shorts.feed
struct ShortItem: Identifiable, Hashable {
    var id: String                 // permalink id, e.g. "v7grk6e"
    var numericID: String          // used for likes and posting comments
    var commentListID: String?     // used to load comments
    var title: String
    var url: String
    var thumbnail: String?
    var duration: Double?
    var streams: [StreamOption]    // mp4, highest first
    var channel: ChannelRef?
    var likes: Int
    var dislikes: Int
    var myVote: Int
    var comments: Int
    var views: Int?

    /// 720p is plenty for a phone-sized vertical video and loads fast.
    var bestStream: StreamOption? {
        streams.first { ($0.height ?? 0) <= 720 } ?? streams.last
    }

    var asVideoItem: VideoItem {
        VideoItem(id: id, url: url, title: title, thumbnail: thumbnail,
                  duration: duration.map { TimeFormat.clock($0) }, channelName: channel?.name,
                  channelPath: channel?.path, channelAvatar: channel?.avatar, views: views.map { CountFormat.short($0) },
                  published: nil, publishedText: nil, live: false, upcoming: false)
    }
}

struct ShortsPage {
    var items: [ShortItem]
    var hasMore: Bool
}

enum ShortsParser {
    static func request(offset: Int, limit: Int = 10) -> URLRequest {
        var c = URLComponents(string: "https://rumble.com/service.php")!
        c.queryItems = [URLQueryItem(name: "name", value: "shorts.feed"), URLQueryItem(name: "offset", value: "\(offset)"),
                        URLQueryItem(name: "limit", value: "\(limit)"), URLQueryItem(name: "api", value: "7")]
        var r = URLRequest(url: c.url!)
        r.setValue("https://rumble.com/shorts", forHTTPHeaderField: "Referer")
        return r
    }

    static func parse(_ data: Data) throws -> ShortsPage {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = obj["data"] as? [String: Any] else { throw AccountError.badResponse }
        let raw = d["items"] as? [[String: Any]] ?? []
        return ShortsPage(items: raw.compactMap(item), hasMore: d["has_more"] as? Bool ?? !raw.isEmpty)
    }

    static func item(_ v: [String: Any]) -> ShortItem? {
        guard let permalink = (v["permalink_id"] as? String) ?? (v["relative_url"] as? String).flatMap(shortId),
              let numeric = int(v["id"]) ?? int((v["rumble_votes"] as? [String: Any])?["content_id"]) else { return nil }
        let streams: [StreamOption] = (v["videos"] as? [[String: Any]] ?? []).compactMap { s in
            guard let url = s["url"] as? String, (s["type"] as? String ?? "mp4") == "mp4" else { return nil }
            return StreamOption(kind: .mp4, height: int(s["res"]) ?? int(s["resolution"]),
                                bitrate: int(s["bitrate_kbps"]), url: url)
        }.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
        guard !streams.isEmpty else { return nil }

        var listID: String?
        if let view = (v["log"] as? [String: Any])?["view"] as? String,
           let r = view.range(of: #"\.\.([0-9a-z]+)\."#, options: .regularExpression) {
            listID = String(view[r].dropFirst(2).dropLast())
        }
        let by = v["by"] as? [String: Any]
        let votes = v["rumble_votes"] as? [String: Any] ?? [:]
        let rel = v["relative_url"] as? String ?? "/shorts/\(permalink)"
        return ShortItem(
            id: permalink.lowercased(),
            numericID: String(int(votes["content_id"]) ?? numeric),
            commentListID: listID,
            title: HTMLText.decodeEntities(v["title"] as? String ?? ""),
            url: v["url"] as? String ?? "https://rumble.com\(rel)",
            thumbnail: v["thumb"] as? String,
            duration: (v["duration"] as? Double) ?? int(v["duration"]).map(Double.init),
            streams: streams,
            channel: (by?["relative_url"] as? String).flatMap(RumbleURL.channelPath(from:)).map {
                ChannelRef(path: $0, name: by?["name"] as? String ?? by?["title"] as? String ?? $0, avatar: by?["thumb"] as? String)
            },
            likes: int(votes["num_votes_up"]) ?? 0,
            dislikes: int(votes["num_votes_down"]) ?? 0,
            myVote: int(votes["user_vote"]) ?? 0,
            comments: int((v["comments"] as? [String: Any])?["count"]) ?? 0,
            views: int(v["views"]))
    }

    static func shortId(_ path: String) -> String? {
        guard let r = path.range(of: #"/shorts/(v[0-9a-zA-Z]+)"#, options: .regularExpression) else { return nil }
        return String(path[r].dropFirst("/shorts/".count))
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
