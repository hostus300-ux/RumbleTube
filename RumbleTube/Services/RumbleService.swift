import Foundation

enum RumbleHTTP {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": "en-US,en;q=0.9"]
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    static func get(_ url: URL) async throws -> (Data, Int) {
        let (data, resp) = try await session.data(from: url)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum RumbleError: LocalizedError {
    case noVideo, noStreams(String?), http(Int)
    var errorDescription: String? {
        switch self {
        case .noVideo: return "Couldn't find the video on that page."
        case .noStreams(let m): return m ?? "This video has no playable streams (it may be private, removed or pay-per-view)."
        case .http(let c): return "Rumble returned an error (\(c))."
        }
    }
}

enum SearchSort: String, CaseIterable, Identifiable {
    case relevance = "Relevance", date = "Newest", views = "Most viewed"
    var id: String { rawValue }
    var param: String? {
        switch self { case .relevance: return nil; case .date: return "date"; case .views: return "views" }
    }
}

/// All Rumble access goes through here.
@MainActor
final class RumbleService {
    static let shared = RumbleService()
    private var detailCache: [String: VideoDetail] = [:]
    private var channelCache: [String: (Date, ListingPage)] = [:]

    // MARK: listings (plain HTTP + parsers; the hidden web view is only a fallback)

    /// Fetch a rumble.com page (with the signed-in cookie when there is one) and parse its videos.
    func listing(_ path: String, page: Int = 1, query: [URLQueryItem] = []) async throws -> ListingPage {
        var c = URLComponents(string: "https://rumble.com" + path)!
        var q = query
        if page > 1 { q.append(URLQueryItem(name: "page", value: "\(page)")) }
        if !q.isEmpty { c.queryItems = (c.queryItems ?? []) + q }
        let url = c.url!
        if let r = try? await RumbleHTTP.get(url), r.1 == 200,
           let parsed = try? ListingParser.parse(String(decoding: r.0, as: UTF8.self), url: url),
           !parsed.items.isEmpty || parsed.channel != nil {
            return parsed
        }
        return try await PageExtractor.shared.extract(url)
    }

    func search(_ query: String, sort: SearchSort = .relevance, page: Int = 1) async throws -> ListingPage {
        var q = [URLQueryItem(name: "q", value: query)]
        if let s = sort.param { q.append(URLQueryItem(name: "sort", value: s)) }
        return try await listing("/search/video", page: page, query: q)
    }

    func searchChannels(_ query: String) async throws -> [ChannelResult] {
        var c = URLComponents(string: "https://rumble.com/search/channel")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, code) = try await RumbleHTTP.get(c.url!)
        guard code == 200 else { throw RumbleError.http(code) }
        return try ChannelSearchParser.parse(String(decoding: data, as: UTF8.self))
    }

    func home() async throws -> HomePage {
        let (data, code) = try await RumbleHTTP.get(URL(string: "https://rumble.com/")!)
        guard code == 200 else { throw RumbleError.http(code) }
        return try HomeParser.parse(String(decoding: data, as: UTF8.self))
    }

    func channel(_ path: String, page: Int = 1, maxAge: TimeInterval = 600) async throws -> ListingPage {
        let key = "\(path.lowercased())#\(page)"
        if let hit = channelCache[key], Date().timeIntervalSince(hit.0) < maxAge { return hit.1 }
        let result = try await listing(path, page: page)
        channelCache[key] = (Date(), result)
        return result
    }

    /// Signed-out fallback for My Feed: latest uploads across locally followed channels, newest first.
    func feed(_ follows: [ChannelRef], force: Bool = false) async -> (items: [VideoItem], failed: [ChannelRef]) {
        var items: [VideoItem] = []
        var failed: [ChannelRef] = []
        await withTaskGroup(of: (ChannelRef, ListingPage?).self) { group in
            for c in follows {
                group.addTask { @MainActor in
                    (c, try? await self.channel(c.path, maxAge: force ? 0 : 600))
                }
            }
            for await (c, page) in group {
                guard let page else { failed.append(c); continue }
                items += page.items.prefix(15).map { v in
                    var v = v
                    if v.channelPath == nil { v.channelPath = c.path }
                    if v.channelName == nil { v.channelName = page.channel?.name ?? c.name }
                    if v.channelAvatar == nil { v.channelAvatar = page.channel?.avatar ?? c.avatar }
                    return v
                }
            }
        }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }
        items.sort { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
        return (items, failed)
    }

    // MARK: My Feed (signed in)

    func followedChannels() async throws -> [FollowedChannel] {
        let (data, resp) = try await RumbleHTTP.session.data(for: authed(FollowingAPI.latestRequest()))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AccountError.notLoggedIn }
        return try FollowingAPI.parseLatest(data)
    }

    func followingFeed(pill: String, offset: Int, limit: Int = 24) async throws -> (items: [VideoItem], raw: [[String: Any]], hasMore: Bool) {
        let (data, resp) = try await RumbleHTTP.session.data(for: authed(FollowingAPI.feedRequest(pill: pill, offset: offset, limit: limit)))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AccountError.notLoggedIn }
        return try FollowingAPI.parseFeed(data)
    }

    private func authed(_ r: URLRequest) -> URLRequest {
        var r = r
        r.setValue("https://rumble.com/subscriptions", forHTTPHeaderField: "Referer")
        return r
    }

    // MARK: video
    func detail(for item: VideoItem) async throws -> VideoDetail {
        if let d = detailCache[item.id], d.liveStatus != .isLive { return d }
        let url = URL(string: RumbleURL.clean(item.url))!

        var html = ""
        if let r = try? await RumbleHTTP.get(url), r.1 == 200 {
            html = String(decoding: r.0, as: UTF8.self)
        }
        var page = WatchPageParser.parse(html)
        if page.embedId == nil {
            // Blocked or changed markup: try the rendered page, then oEmbed.
            if let rendered = try? await PageExtractor.shared.html(url) { page = WatchPageParser.parse(rendered) }
        }
        if page.embedId == nil { page.embedId = await embedIdFromOEmbed(url) }
        guard let embedId = page.embedId else { throw RumbleError.noVideo }

        var c = URLComponents(string: "https://rumble.com/embedJS/u3/")!
        c.queryItems = [URLQueryItem(name: "request", value: "video"), URLQueryItem(name: "ver", value: "2"),
                        URLQueryItem(name: "v", value: embedId)]
        let (data, code) = try await RumbleHTTP.get(c.url!)
        guard code == 200 else { throw RumbleError.http(code) }
        guard let embed = EmbedParser.parse(data) else { throw RumbleError.noVideo }
        guard !embed.streams.isEmpty else { throw RumbleError.noStreams(embed.message) }

        var detail = VideoDetailBuilder.build(id: item.id, url: url.absoluteString, page: page, embed: embed, embedId: embedId)
        if detail.channel == nil, let c = item.channel { detail.channel = c }
        if detail.channel?.avatar == nil { detail.channel?.avatar = item.channelAvatar }
        if detail.thumbnail == nil { detail.thumbnail = item.thumbnail }
        if let chat = LiveChatParser.config(fromWatchPage: html) {
            detail.chatAPI = chat.apiBase; detail.chatID = chat.chatID; detail.rantsAPI = chat.rantsBase
            detail.rantLevels = chat.rantLevels.map { [$0.dollars, $0.seconds] }
        }
        detailCache[item.id] = detail
        return detail
    }

    private func embedIdFromOEmbed(_ url: URL) async -> String? {
        var c = URLComponents(string: "https://rumble.com/api/Media/oembed.json")!
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let r = try? await RumbleHTTP.get(c.url!), r.1 == 200,
              let obj = (try? JSONSerialization.jsonObject(with: r.0)) as? [String: Any],
              let html = obj["html"] as? String else { return nil }
        return WatchPageParser.first(html, #"rumble\.com/embed/([0-9a-z.]+)"#).flatMap {
            WatchPageParser.embedId(fromURL: "https://rumble.com/embed/\($0)/")
        }
    }

    /// Accepts a pasted rumble.com link; returns a minimal item to open.
    static func item(fromLink s: String) -> VideoItem? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().contains("rumble.com"), let id = RumbleURL.videoId(from: trimmed) else { return nil }
        return VideoItem(id: id, url: RumbleURL.clean(trimmed), title: "Loading…")
    }
}
