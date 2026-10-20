import Foundation

/// A video as it appears in a list (search, channel, feed).
struct VideoItem: Codable, Hashable, Identifiable {
    /// Watch-page id, e.g. "v6abc12" (lowercased). Also the RumbleSkip key.
    var id: String
    var url: String
    var title: String
    var thumbnail: String?
    var duration: String?
    var channelName: String?
    var channelPath: String?
    var channelAvatar: String?
    var views: String?
    var published: String?
    var publishedText: String?
    var live: Bool?
    var upcoming: Bool?
    /// Live viewers right now.
    var watching: Int? = nil
    var isShort: Bool? = nil
    /// Where Rumble says you stopped watching (seconds).
    var progress: Double? = nil
    /// Rumble's numeric id (likes, comments).
    var numericID: String? = nil
    /// Embed id without the "v" (comment list).
    var commentListID: String? = nil

    var publishedDate: Date? { published.flatMap(DateParsing.iso8601) }
    var durationSeconds: Double? { duration.flatMap(TimeFormat.parseClock) }
    var isLive: Bool { live == true }

    var channel: ChannelRef? {
        guard let p = channelPath else { return nil }
        return ChannelRef(path: p, name: channelName ?? p, avatar: channelAvatar)
    }
}

/// Lightweight pointer to a channel (what we store when following).
struct ChannelRef: Codable, Hashable, Identifiable {
    /// "/c/Name" or "/user/Name"
    var path: String
    var name: String
    var avatar: String?
    var id: String { path.lowercased() }
    var url: URL { URL(string: "https://rumble.com" + path)! }
}

struct ChannelHeader: Codable, Hashable {
    var path: String
    var name: String
    var avatar: String?
    var banner: String?
    var followers: String?
    /// Rumble's numeric channel/user id and type, used to follow/unfollow on Rumble.
    var rumbleID: String? = nil
    var rumbleType: String? = nil
    var followingOnRumble: Bool? = nil
}

/// Result of extracting one listing page.
struct ListingPage: Codable {
    var items: [VideoItem]
    var hasNext: Bool
    var channel: ChannelHeader?
    var empty: Bool?
}

enum StreamKind: String, Codable { case hls, mp4 }

struct StreamOption: Codable, Hashable, Identifiable {
    var kind: StreamKind
    var height: Int?
    var bitrate: Int?
    var url: String
    var id: String { url }

    var label: String {
        switch kind {
        case .hls: return height.map { "\($0)p (HLS)" } ?? "Auto"
        case .mp4: return height.map { "\($0)p" } ?? "MP4"
        }
    }
}

enum LiveStatus: String, Codable { case notLive, isLive, upcoming, wasLive }

/// Everything the player needs for one video.
struct VideoDetail: Codable, Hashable {
    var id: String
    var url: String
    var embedId: String
    var title: String
    var description: String?
    var thumbnail: String?
    var duration: Double?
    var published: Date?
    var views: Int?
    var likes: String?
    var dislikes: String?
    var channel: ChannelRef?
    var channelFollowers: String?
    var liveStatus: LiveStatus
    var streams: [StreamOption]

    /// Best default: adaptive HLS, else the highest MP4 up to 1080p.
    var defaultStream: StreamOption? {
        if let hls = streams.first(where: { $0.kind == .hls }) { return hls }
        let mp4 = streams.filter { $0.kind == .mp4 }.sorted { ($0.height ?? 0) < ($1.height ?? 0) }
        return mp4.last(where: { ($0.height ?? 0) <= 1080 }) ?? mp4.last
    }

    var asItem: VideoItem {
        VideoItem(id: id, url: url, title: title, thumbnail: thumbnail,
                  duration: duration.map { TimeFormat.clock($0) }, channelName: channel?.name,
                  channelPath: channel?.path, channelAvatar: channel?.avatar, views: views.map { "\($0)" },
                  published: published.map { ISO8601DateFormatter().string(from: $0) }, publishedText: nil,
                  live: liveStatus == .isLive, upcoming: liveStatus == .upcoming)
    }
}

enum RumbleURL {
    /// Watch id from a rumble.com watch URL or path ("/v6abc12-title.html" → "v6abc12").
    static func videoId(from string: String) -> String? {
        let path: String
        if let u = URL(string: string), u.host != nil { path = u.path } else { path = string }
        if let sr = path.range(of: #"^/shorts/v[a-zA-Z0-9]{3,15}"#, options: [.regularExpression, .caseInsensitive]) {
            return String(path[sr].dropFirst("/shorts/".count)).lowercased()
        }
        guard let r = path.range(of: #"^/?(v[a-zA-Z0-9]{3,15})-[^?#]*\.html"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let match = String(path[r]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let dash = match.firstIndex(of: "-") else { return nil }
        return String(match[..<dash]).lowercased()
    }

    /// Canonical watch URL without tracking query.
    static func clean(_ string: String) -> String {
        guard var c = URLComponents(string: string) else { return string }
        c.query = nil; c.fragment = nil
        if c.host == nil { c.scheme = "https"; c.host = "rumble.com" }
        return c.string ?? string
    }

    /// Channel path from a URL or path ("/c/Name", "/user/Name").
    static func channelPath(from string: String) -> String? {
        let path = URL(string: string).flatMap { $0.host != nil ? $0.path : nil } ?? string
        guard let r = path.range(of: #"^/(c|user)/[^/?#]+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(path[r])
    }
}
