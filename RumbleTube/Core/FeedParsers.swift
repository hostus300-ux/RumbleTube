import Foundation
import SwiftSoup
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Parsers for Rumble pages and JSON feeds. Everything here works on plain HTTP responses
// (no web view): the homepage and channel pages embed their videos as JSON, and listing
// pages (Editor Picks, Live, categories, search) are server-rendered cards.

// MARK: - Rumble's JSON video object (used by homepage rows, channel grids, My Feed, notifications)

enum RumbleJSON {
    static func video(_ v: [String: Any]) -> VideoItem? {
        let rel = (v["relative_url"] as? String) ?? (v["url"] as? String)
        let permalink = (v["permalink_id"] as? String)?.lowercased()
        guard let id = rel.flatMap(RumbleURL.videoId(from:)) ?? permalink else { return nil }
        let isShort = (v["is_short"] as? Bool) ?? (rel?.contains("/shorts/") ?? false)
        let url = rel.map(RumbleURL.clean) ?? (isShort ? "https://rumble.com/shorts/\(id)" : "https://rumble.com/\(id)")
        let by = v["by"] as? [String: Any]
        let dur = num(v["duration"])
        let status = int(v["livestream_status"])
        let live = (v["live"] as? Bool) == true && status != 1 ? true : (status == 2)
        var listID: String?
        if let view = (v["log"] as? [String: Any])?["view"] as? String,
           let r = view.range(of: #"\.\.([0-9a-z]+)\."#, options: .regularExpression) {
            listID = String(view[r].dropFirst(2).dropLast())
        }
        var item = VideoItem(
            id: id, url: url, title: HTMLText.decodeEntities(v["title"] as? String ?? ""),
            thumbnail: v["thumb"] as? String,
            duration: (dur ?? 0) > 0 ? TimeFormat.clock(dur!) : nil,
            channelName: by?["title"] as? String ?? by?["name"] as? String,
            channelPath: ((by?["relative_url"] as? String) ?? (by?["url"] as? String)).flatMap(RumbleURL.channelPath(from:)),
            channelAvatar: by?["thumb"] as? String,
            views: int(v["views"]).map { CountFormat.short($0) },
            published: v["upload_date"] as? String, publishedText: nil,
            live: live, upcoming: status == 1 || (v["live_placeholder"] as? Bool) == true)
        item.watching = live ? int(v["watching_now"]) : nil
        item.isShort = isShort
        item.progress = num((v["watching_progress"] as? [String: Any])?["last_time"]).flatMap { $0 > 0 ? $0 : nil }
        item.numericID = int((v["rumble_votes"] as? [String: Any])?["content_id"]).map(String.init) ?? int(v["id"]).map(String.init)
        item.commentListID = listID
        let votes = v["rumble_votes"] as? [String: Any]
        item.viewCount = int(v["views"])
        item.likes = int(votes?["num_votes_up"])
        item.dislikes = int(votes?["num_votes_down"])
        item.commentCount = int((v["comments"] as? [String: Any])?["count"])
        return item.title.isEmpty ? nil : item
    }

    static func videos(_ arr: Any?) -> [VideoItem] {
        (arr as? [[String: Any]] ?? []).compactMap(video)
    }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
    static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - Homepage

struct HomePill: Hashable, Identifiable, Codable { var id: String; var title: String }

struct HomeRow: Identifiable, Codable {
    var id: String
    var title: String
    var feedPath: String?
    var items: [VideoItem]
}

struct HomePage: Codable {
    var hero: [VideoItem]
    var rows: [HomeRow]
    var pills: [HomePill]
}

enum HomeParser {
    static func parse(_ html: String) throws -> HomePage {
        let doc = try SwiftSoup.parse(html)
        var hero: [VideoItem] = []
        var rows: [HomeRow] = []
        var pills: [HomePill] = []
        for script in try doc.select("script[type=application/json]").array() {
            guard let parent = script.parent(), let data = script.data().data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let tag = parent.tagName()
            if tag == "rum-featured-pills-row" {
                pills = (json["pills"] as? [[String: Any]] ?? []).compactMap { p in
                    guard let id = p["id"] as? String, let t = p["title"] as? String, id != "feed", id != "shorts_videos" else { return nil }
                    return HomePill(id: id, title: t)
                }
            } else if tag == "rum-player-row-thumbnail-sidebar-provider" {
                hero = RumbleJSON.videos(json["items"]).filter { $0.isShort != true }
            } else if tag == "rum-videos-row-provider" {
                // Shorts rows stay in the Shorts tab only.
                if (try? parent.attr("kind")) == "shorts" { continue }
                var items = RumbleJSON.videos(json["items"]).filter { $0.isShort != true }
                guard !items.isEmpty else { continue }
                let path = try parent.attr("feed-path")
                if path.hasPrefix("/category/") {
                    let cat = try parent.attr("row-title")
                    for i in items.indices { items[i].category = cat }
                }
                rows.append(HomeRow(id: try parent.attr("row-id"), title: try parent.attr("row-title"),
                                    feedPath: path.isEmpty ? nil : path, items: items))
            }
        }
        pills = pills.filter { p in rows.contains { $0.id == p.id } }
        return HomePage(hero: hero, rows: rows, pills: pills)
    }
}

// MARK: - Listing pages (channel, category, editor picks, live, search, history)

enum ListingParser {
    static func parse(_ html: String, url: URL) throws -> ListingPage {
        let doc = try SwiftSoup.parse(html, url.absoluteString)
        var items: [VideoItem] = []

        // 1. Channel pages: <rum-videos-grid><script type="application/json">{"items":[…]}
        for script in try doc.select("rum-videos-grid > script[type=application/json]").array() {
            guard let data = script.data().data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            items += RumbleJSON.videos(json["items"])
        }
        // 2. Server-rendered cards: .videostream (editor picks, live, categories, channels) and article.video-item (search)
        for el in try doc.select(".videostream, article.video-item").array() {
            if let v = try card(el) { items.append(v) }
        }

        var seen = Set<String>()
        items = items.filter { $0.isShort != true && seen.insert($0.id).inserted }
        return ListingPage(items: items, hasNext: try hasNext(doc, url: url), channel: try channelHeader(doc, url: url),
                           empty: items.isEmpty)
    }

    private static func card(_ c: Element) throws -> VideoItem? {
        // skip sidebar/nav and shorts shelves
        var p: Element? = c
        while let e = p {
            let cls = (try? e.className()) ?? ""
            if cls.contains("main-menu") || e.tagName().contains("shorts") || cls.range(of: #"(^|\s)shorts"#, options: .regularExpression) != nil { return nil }
            p = e.parent()
        }
        let links = try c.select("a[href]").array().filter { a in
            let h = (try? a.attr("href")) ?? ""
            return RumbleURL.videoId(from: h) != nil && !h.contains("/shorts/") && !((try? a.className()) ?? "").contains("btn")
        }
        guard let link = links.first, let id = RumbleURL.videoId(from: try link.attr("href")) else { return nil }
        let title = try c.select("h3").first()?.text() ?? (try c.select("img").first()?.attr("alt")) ?? ""
        guard !title.isEmpty else { return nil }
        let thumb = try c.select("img.thumbnail__image, img.video-item--img, .thumbnail__thumb img").first()?.attr("src")
        let chanLink = try c.select("a[href^=/c/], a[href^=/user/], a[rel=author]").first()
        let chanPath = try chanLink.map { try $0.attr("href") }.flatMap(RumbleURL.channelPath(from:))
        let chanName = try c.select(".channel__name, .video-item--by-a .ellipsis-1").first()?.text()
            .replacingOccurrences(of: #"Verified$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let avatar = try c.select("img.channel__image").first()?.attr("src")
        let liveBadge = try c.select(".videostream__status--live, .video-item--live, .thumbnail__thumb--live").first() != nil
        let upcoming = try c.select(".videostream__status--upcoming, .video-item--upcoming").first() != nil
        var duration: String?
        if let d = try c.select(".videostream__status--duration, .video-item--duration").first() {
            let dv = (try? d.attr("data-value")) ?? ""
            let t = dv.isEmpty ? try d.text() : dv
            if TimeFormat.parseClock(t) != nil { duration = t }
        }
        var views: String?
        var viewCount: Int?
        if let v = try c.select(".videostream__views").first() {
            viewCount = (try? v.attr("data-views")).flatMap { Int($0) }
            views = viewCount.map { CountFormat.short($0) }
        }
        if views == nil, let v = try c.select(".video-item--views").first() { views = try v.text() }
        var watching: Int?
        if liveBadge, let n = try c.select(".videostream__number").first() { watching = CountFormat.parse(try n.text()) }
        let time = try c.select("time").first()
        var item = VideoItem(id: id, url: RumbleURL.clean(try link.attr("href")), title: HTMLText.decodeEntities(title),
                             thumbnail: thumb?.hasPrefix("http") == true ? thumb : nil, duration: duration,
                             channelName: (chanName?.isEmpty == false ? chanName : nil) ?? chanPath.map { String($0.split(separator: "/").last ?? "") },
                             channelPath: chanPath, channelAvatar: avatar, views: views,
                             published: try time?.attr("datetime"), publishedText: try time?.text(),
                             live: liveBadge, upcoming: upcoming)
        item.viewCount = viewCount ?? views.flatMap { CountFormat.parse($0) }
        item.watching = watching
        if let vid = try? c.attr("data-video-id"), !vid.isEmpty { item.numericID = vid }
        return item
    }

    private static func hasNext(_ doc: Document, url: URL) throws -> Bool {
        let cur = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value ?? "1") ?? 1
        for a in try doc.select("a[href*=page=]").array() {
            let h = try a.attr("href")
            guard let c = URLComponents(string: h.hasPrefix("http") ? h : "https://rumble.com" + h) else { continue }
            if c.path.lowercased() == url.path.lowercased(), Int(c.queryItems?.first { $0.name == "page" }?.value ?? "") == cur + 1 { return true }
        }
        return false
    }

    private static func channelHeader(_ doc: Document, url: URL) throws -> ChannelHeader? {
        guard let path = RumbleURL.channelPath(from: url.path) else { return nil }
        let head = try doc.select(".channel-header--container").first()
        let name = try (head ?? doc).select("h1").first()?.text() ?? String(path.split(separator: "/").last ?? "")
        let avatar = try head?.select("img.channel-header--img").first()?.attr("src")
        let banner = try head?.select(".channel-header--backsplash img").first()?.attr("src")
        let text = try head?.text() ?? ""
        let followers = text.range(of: #"[\d.,]+\s*[KMB]?(?=\s+Followers)"#, options: .regularExpression).map { String(text[$0]).replacingOccurrences(of: " ", with: "") }
        var header = ChannelHeader(path: path, name: name, avatar: avatar, banner: banner, followers: followers)
        if let f = try doc.select(".followed-channel[data-id]").first() {
            header.rumbleID = try f.attr("data-id")
            header.rumbleType = try f.attr("data-type")
            if let b = try f.select("[data-following]").first() { header.followingOnRumble = (try b.attr("data-following")) == "1" }
        }
        return header
    }
}

// MARK: - My Feed (following-latest / following-feed)

struct FollowedChannel: Identifiable, Hashable, Codable {
    var ref: ChannelRef
    var lastActivity: Date?
    var liveViewers: Int?
    var followers: Int?
    var id: String { ref.id }
    var isLive: Bool { (liveViewers ?? 0) > 0 }
}

enum MyFeedPill: String, CaseIterable, Identifiable {
    case all, today, live, videos
    case continueWatching = "continue-watching"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .today: return "Today"
        case .live: return "Live"
        case .videos: return "Videos"
        case .continueWatching: return "Continue Watching"
        }
    }
}

enum FollowingAPI {
    static func latestRequest(limit: Int = 50) -> URLRequest {
        URLRequest(url: URL(string: "https://rumble.com/-api/user/following-latest?limit=\(limit)")!)
    }

    static func feedRequest(pill: String, offset: Int, limit: Int = 24, creatorID: String? = nil,
                            timeZone: String = TimeZone.current.identifier) -> URLRequest {
        var c = URLComponents(string: "https://rumble.com/-api/user/following-feed")!
        let shorts = pill == "shorts"
        var q = [URLQueryItem(name: "limit", value: "\(limit)"), URLQueryItem(name: "offset", value: "\(offset)"),
                 URLQueryItem(name: "options", value: shorts ? "video.full,video.vertical_thumb" : "video.full,video.watching_progress"),
                 URLQueryItem(name: "tzi", value: timeZone), URLQueryItem(name: "pill", value: pill)]
        if let creatorID { q.append(URLQueryItem(name: "creator_id", value: creatorID)) }
        c.queryItems = q
        return URLRequest(url: c.url!)
    }

    static func parseLatest(_ data: Data) throws -> [FollowedChannel] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = obj["data"] as? [String: Any] else { throw AccountError.badResponse }
        return (d["items"] as? [[String: Any]] ?? []).compactMap { c in
            guard let url = c["url"] as? String, let path = RumbleURL.channelPath(from: url) else { return nil }
            let name = c["title"] as? String ?? c["name"] as? String ?? path
            return FollowedChannel(ref: ChannelRef(path: path, name: name, avatar: c["thumb"] as? String),
                                   lastActivity: (c["last_activity"] as? String).flatMap(DateParsing.iso8601),
                                   liveViewers: RumbleJSON.int(c["watching_now_count"]),
                                   followers: RumbleJSON.int(c["followers"]))
        }
    }

    /// Videos (and, separately, shorts) from followed creators.
    static func parseFeed(_ data: Data) throws -> (items: [VideoItem], raw: [[String: Any]], hasMore: Bool) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = obj["data"] as? [String: Any] else { throw AccountError.badResponse }
        let raw = d["items"] as? [[String: Any]] ?? []
        return (raw.compactMap(RumbleJSON.video), raw, d["has_more"] as? Bool ?? false)
    }
}

// MARK: - Account pages

struct EarningsLine: Identifiable, Hashable { var label: String; var amount: String; var id: String { label } }

enum AccountPages {
    /// /account/earnings: each <section> holds an amount and its label.
    static func earnings(_ html: String) throws -> [EarningsLine] {
        let doc = try SwiftSoup.parse(html)
        var out: [EarningsLine] = []
        for s in try doc.select("section").array() {
            let text = try s.text()
            guard let r = text.range(of: #"\$[\d,]+(\.\d{2})?"#, options: .regularExpression) else { continue }
            let label = try s.select("h3").first()?.text() ?? s.select(".sr-only").first()?.text() ?? ""
            let clean = label.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, !out.contains(where: { $0.label == clean }) else { continue }
            out.append(EarningsLine(label: clean, amount: String(text[r])))
        }
        return out
    }

    /// "12.3K Followers" on a profile/channel page.
    static func followers(_ html: String) -> String? {
        guard let r = html.range(of: #"([\d.,]+\s*[KMB]?)\s*(<[^>]+>\s*)*Followers"#, options: .regularExpression) else { return nil }
        let m = String(html[r])
        return m.range(of: #"^[\d.,]+\s*[KMB]?"#, options: .regularExpression).map { String(m[$0]).replacingOccurrences(of: " ", with: "") }
    }

    /// First avatar image in the signed-in header fragment.
    static func avatar(_ html: String) -> String? {
        html.range(of: #"https://[^"' )]+\.(jpe?g|png|webp)"#, options: .regularExpression).map { String(html[$0]) }
    }
}

// MARK: - Follow / unfollow on Rumble

enum FollowAPI {
    /// Same request Rumble's Follow button sends (htmx form post).
    static func toggleRequest(id: String, type: String, follow: Bool) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://rumble.com/-htmx/account/legacy-video-collection")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("true", forHTTPHeaderField: "HX-Request")
        r.setValue("https://rumble.com", forHTTPHeaderField: "Origin")
        r.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        r.httpBody = Data(AccountRequests.formEncode([
            "collection_id": id, "type": type, "action": "toggle-following-status",
            "state": follow ? "1" : "0", "size": "default",
        ]).utf8)
        return r
    }
}

// MARK: - Channel search (/search/channel?q=)

struct ChannelResult: Identifiable, Hashable {
    var ref: ChannelRef
    var followers: String?
    var verified: Bool
    var id: String { ref.id }
}

enum ChannelSearchParser {
    static func parse(_ html: String) throws -> [ChannelResult] {
        let doc = try SwiftSoup.parse(html)
        // Avatars are CSS background images: .user-image--img--id-N { background-image: url(...) }
        var avatars: [String: String] = [:]
        let pattern = #"user-image--img--id-(\d+)\s*\{\s*background-image:\s*url\(([^)]+)\)"#
        if let re = try? NSRegularExpression(pattern: pattern) {
            let ns = html as NSString
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                avatars[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
            }
        }
        var out: [ChannelResult] = []
        var seen = Set<String>()
        for art in try doc.select("article").array() {
            guard let a = try art.select("a[href]").first(),
                  let path = RumbleURL.channelPath(from: try a.attr("href").components(separatedBy: "?")[0]),
                  seen.insert(path.lowercased()).inserted else { continue }
            let name = try art.select("h3 span.truncate, h3 span").first()?.text() ?? path
            var avatar: String?
            if let i = try art.select("i.user-image").first(),
               let cls = try i.className().components(separatedBy: " ").first(where: { $0.hasPrefix("user-image--img--id-") }) {
                avatar = avatars[String(cls.dropFirst("user-image--img--id-".count))]
            }
            let followersText = try art.select("span").array().compactMap { try? $0.text() }
                .first { $0.lowercased().contains("follower") }
            let followers = followersText.map { $0.replacingOccurrences(of: "Followers", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces) }
            out.append(ChannelResult(ref: ChannelRef(path: path, name: name, avatar: avatar), followers: followers,
                                     verified: try !art.select(".verification-badge-icon").isEmpty()))
        }
        return out
    }
}
