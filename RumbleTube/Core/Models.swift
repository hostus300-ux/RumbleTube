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
    /// Raw numbers for ranking (Discover).
    var viewCount: Int? = nil
    var likes: Int? = nil
    var dislikes: Int? = nil
    var commentCount: Int? = nil
    /// Section/category it was found in (e.g. "News"), used for personal ranking.
    var category: String? = nil
    /// Rumble's green verified check next to the channel name.
    var channelVerified: Bool? = nil

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
    var verified: Bool? = nil
    /// The channel offers paid memberships ("Join" on rumble.com).
    var joinable: Bool? = nil
    /// Rumble Wallet tip id (the "Tip" button's QR code), when the creator set one up.
    var tipID: String? = nil
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
    /// Live chat endpoint from the watch page.
    var chatAPI: String? = nil
    var chatID: String? = nil
    var rantsAPI: String? = nil
    var rantLevels: [[Int]]? = nil
    var channelVerified: Bool? = nil
    var channelJoinable: Bool? = nil
    var tipID: String? = nil
    var chat: ChatConfig? {
        guard let a = chatAPI, let i = chatID else { return nil }
        var c = ChatConfig(apiBase: a, chatID: i, rantsBase: rantsAPI)
        if let l = rantLevels, !l.isEmpty { c.rantLevels = l.map { RantLevel(dollars: $0[0], seconds: $0[1]) } }
        return c
    }

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

// MARK: - Downloads

/// A video saved for offline viewing.
struct DownloadRecord: Codable, Hashable, Identifiable {
    var detail: VideoDetail
    var item: VideoItem
    var fileName: String          // inside Documents/Downloads
    var thumbFile: String?
    var bytes: Int64
    var quality: String
    var savedAt: Date
    var id: String { item.id }
}

enum DownloadPlan {
    /// Best MP4 at or under `maxHeight` (HLS can't be saved as one file). Lowest MP4 if all are bigger.
    static func stream(from streams: [StreamOption], maxHeight: Int) -> StreamOption? {
        let mp4 = streams.filter { $0.kind == .mp4 }
        return mp4.filter { ($0.height ?? 0) <= maxHeight }.max { ($0.height ?? 0) < ($1.height ?? 0) }
            ?? mp4.min { ($0.height ?? 0) < ($1.height ?? 0) }
    }

    static let qualityChoices = [360, 480, 720, 1080]

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
