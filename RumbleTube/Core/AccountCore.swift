import Foundation
import SwiftSoup
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Comments

/// One comment from rumble.com/service.php?name=comment.list (replies nested).
struct RumbleComment: Identifiable, Hashable {
    var id: String
    var author: String
    var authorPath: String?
    var avatar: String?
    var text: String
    var timeText: String
    var timeTitle: String?
    var upVotes: Int
    var downVotes: Int
    var numReplies: Int
    var actions: [String]
    var videoNumericID: String?
    var pinned: Bool
    var verified: Bool
    var isVideoOwner: Bool
    var replies: [RumbleComment]

    var canReply: Bool { actions.contains("reply") }
    var canDelete: Bool { actions.contains("delete") }
    /// Rumble keeps a deleted comment (shown as "[deleted]"; its author gets "restore" instead of "delete").
    var isDeleted: Bool { actions.contains("restore") || text == "[deleted]" }
}

struct CommentPage {
    var comments: [RumbleComment]
    var totalText: String?
    var videoNumericID: String?

    /// Every comment, depth-first.
    var flattened: [RumbleComment] {
        var out: [RumbleComment] = []
        func walk(_ c: RumbleComment) { out.append(c); c.replies.forEach(walk) }
        comments.forEach(walk)
        return out
    }

    /// Path of ids from a top-level comment down to `id` (inclusive), or nil.
    func path(to id: String) -> [String]? {
        func search(_ c: RumbleComment, _ trail: [String]) -> [String]? {
            let t = trail + [c.id]
            if c.id == id { return t }
            for r in c.replies { if let p = search(r, t) { return p } }
            return nil
        }
        for c in comments { if let p = search(c, []) { return p } }
        return nil
    }

    func comment(_ id: String) -> RumbleComment? { flattened.first { $0.id == id } }

    /// The top-level comment whose thread contains `id`.
    func thread(containing id: String) -> RumbleComment? {
        guard let root = path(to: id)?.first else { return nil }
        return comments.first { $0.id == root }
    }
}

enum CommentParser {
    /// Parses the JSON returned by comment.list.
    static func parse(_ data: Data) throws -> CommentPage {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AccountError.badResponse
        }
        if let d = obj["data"] as? [String: Any], let e = d["error"] as? String, !e.isEmpty { throw AccountError.server(e) }
        let html = obj["html"] as? String ?? ""
        var css = ""
        if let libs = obj["css_libs"] as? [String: Any] { css = libs.values.compactMap { $0 as? String }.joined(separator: "\n") }
        else if let s = obj["css_libs"] as? String { css = s }
        return try parse(html: html, css: css)
    }

    static func parse(html: String, css: String) throws -> CommentPage {
        let avatars = avatarMap(css)
        let doc = try SwiftSoup.parseBodyFragment(html)
        let total = try doc.select("h3.comment-count").first()?.text()
        guard let top = try doc.select("ul.comments-1").first() else {
            return CommentPage(comments: [], totalText: total, videoNumericID: nil)
        }
        let comments = try items(in: top, avatars: avatars)
        let vid = try doc.select("li.comment-item[data-video-fid]").first()?.attr("data-video-fid")
        return CommentPage(comments: comments, totalText: total, videoNumericID: vid?.isEmpty == false ? vid : nil)
    }

    private static func items(in ul: Element, avatars: [String: String]) throws -> [RumbleComment] {
        try ul.children().array().compactMap { li in
            guard li.hasClass("comment-item"), !li.hasClass("comments-create") else { return nil }
            let id = try li.attr("data-comment-id")
            guard !id.isEmpty else { return nil }
            return try comment(li, id: id, avatars: avatars)
        }
    }

    private static func comment(_ li: Element, id: String, avatars: [String: String]) throws -> RumbleComment {
        // Only look at this comment's own meta, not nested replies.
        let meta = li.children().array().first { $0.hasClass("comments-meta") }
        let authorEl = try meta?.select("a.comments-meta-author").first()
        let timeEl = try meta?.select("a.comments-meta-post-time").first()
        let textEl = li.children().array().first { $0.tagName() == "p" && $0.hasClass("comment-text") }
        let actionsWrap = li.children().array().first { $0.hasClass("comment-actions-wrapper") }
        let up = try actionsWrap?.select("span.rumbles-up-votes").first()?.text() ?? "0"
        let down = try actionsWrap?.select("span.rumbles-down-votes").first()?.text() ?? "0"

        var avatar: String?
        if let icon = li.children().array().first(where: { $0.hasClass("user-image") }) {
            for cls in try icon.classNames() where cls.hasPrefix("user-image--img--id-") {
                avatar = avatars[String(cls.dropFirst("user-image--img--id-".count))]
            }
        }

        var replies: [RumbleComment] = []
        if let wrap = li.children().array().first(where: { $0.hasClass("comment-replies") }),
           let ul = wrap.children().array().first(where: { $0.tagName() == "ul" }) {
            replies = try items(in: ul, avatars: avatars)
        }

        let username = try li.attr("data-username")
        return RumbleComment(
            id: id,
            author: (try authorEl?.text()).flatMap { $0.isEmpty ? nil : $0 } ?? username,
            authorPath: try authorEl?.attr("href"),
            avatar: avatar,
            text: textEl.map(plainText) ?? "",
            timeText: try timeEl?.text() ?? "",
            timeTitle: try timeEl?.attr("title"),
            upVotes: CountFormat.parse(up) ?? 0,
            downVotes: CountFormat.parse(down) ?? 0,
            numReplies: Int(try li.attr("data-num-replies")) ?? replies.count,
            actions: try li.attr("data-actions").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            videoNumericID: try li.attr("data-video-fid"),
            pinned: (try meta?.select("span.pinned-text").first()) != nil,
            verified: (try meta?.select("img[alt=Verified]").first()) != nil,
            isVideoOwner: (try meta?.select("a.comments-meta-author-video-owner").first()) != nil,
            replies: replies)
    }

    /// Keeps line breaks from <br> while dropping other markup.
    private static func plainText(_ el: Element) -> String {
        (try? el.html()).map(HTMLText.plain) ?? ((try? el.text()) ?? "")
    }

    /// "i.user-image--img--id-abc { background-image: url(https://…) }" → ["abc": "https://…"]
    static func avatarMap(_ css: String) -> [String: String] {
        let pattern = #"i\.user-image--img--id-(\w+)\s*\{\s*background-image:\s*url\(\s*['"]?([^)'"]+)['"]?\s*\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = css as NSString
        var out: [String: String] = [:]
        for m in re.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return out
    }
}

// MARK: - Notifications

struct RumbleNotification: Identifiable, Hashable {
    var id: String
    var type: String
    var body: String
    var createdOn: Date?
    var createdText: String?
    var read: Bool
    var commentID: String?
    var actorName: String?
    var actorAvatar: String?
    var actorPath: String?
    var video: VideoItem?
    /// Rumble embed id without the leading "v" (what comment.list wants), when known.
    var commentListID: String?
    var videoNumericID: String?

    var isCommentRelated: Bool { commentID != nil || type.contains("comment") || type.contains("reply") || type.contains("mention") }
}

struct NotificationFeed {
    var items: [RumbleNotification]
    var hasUnread: Bool
    var loggedIn: Bool
}

enum NotificationParser {
    static func parse(_ data: Data) throws -> NotificationFeed {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AccountError.badResponse }
        let user = obj["user"] as? [String: Any]
        let loggedIn = user?["logged_in"] as? Bool ?? false
        let d = obj["data"] as? [String: Any] ?? [:]
        let raw = d["items"] as? [[String: Any]] ?? []
        let items = raw.compactMap(item)
        return NotificationFeed(items: items, hasUnread: d["has_unread"] as? Bool ?? items.contains { !$0.read },
                                loggedIn: loggedIn)
    }

    static func item(_ n: [String: Any]) -> RumbleNotification? {
        guard let id = str(n["id"]) else { return nil }
        let actor = n["user"] as? [String: Any] ?? n["channel"] as? [String: Any]
        var video: VideoItem?
        var listID: String?
        var numeric: String?
        if let v = n["video"] as? [String: Any], let rel = v["relative_url"] as? String ?? v["url"] as? String,
           let vid = RumbleURL.videoId(from: rel) {
            let by = v["by"] as? [String: Any]
            let dur = (v["duration"] as? Double) ?? (v["duration"] as? Int).map(Double.init)
            video = VideoItem(
                id: vid, url: RumbleURL.clean(rel), title: HTMLText.decodeEntities(v["title"] as? String ?? "Video"),
                thumbnail: v["thumb"] as? String, duration: dur.flatMap { $0 > 0 ? TimeFormat.clock($0) : nil },
                channelName: by?["name"] as? String ?? by?["title"] as? String,
                channelPath: (by?["relative_url"] as? String).flatMap(RumbleURL.channelPath(from:)),
                channelAvatar: by?["thumb"] as? String, views: (v["views"] as? Int).map { CountFormat.short($0) },
                published: v["upload_date"] as? String, publishedText: nil,
                live: v["live"] as? Bool, upcoming: nil)
            numeric = str(v["id"])
            // "/l/view.mcaxl..7d4y3s.og5ch4" → "7d4y3s"
            if let view = (v["log"] as? [String: Any])?["view"] as? String,
               let r = view.range(of: #"\.\.([0-9a-z]+)\."#, options: .regularExpression) {
                listID = String(view[r].dropFirst(2).dropLast())
            }
        }
        return RumbleNotification(
            id: id,
            type: n["type"] as? String ?? "notification",
            body: HTMLText.decodeEntities(n["body"] as? String ?? ""),
            createdOn: (n["created_on"] as? String).flatMap(DateParsing.iso8601),
            createdText: n["created_on_formatted"] as? String,
            read: !(n["read_on"] is NSNull) && n["read_on"] != nil,
            commentID: str(n["comment_id"]),
            actorName: actor?["title"] as? String ?? actor?["name"] as? String,
            actorAvatar: actor?["thumb"] as? String,
            actorPath: (actor?["url"] as? String).flatMap(RumbleURL.channelPath(from:)),
            video: video, commentListID: listID, videoNumericID: numeric)
    }

    private static func str(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double { return String(Int(d)) }
        return nil
    }
}

// MARK: - Account API requests (session cookie is attached by URLSession)

enum AccountError: LocalizedError, Equatable {
    case notLoggedIn, badResponse, server(String), http(Int)
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Sign in to Rumble first (Settings → Rumble account)."
        case .badResponse: return "Rumble sent something unexpected."
        case .server(let m): return m
        case .http(let c): return "Rumble returned an error (\(c))."
        }
    }
}

enum AccountRequests {
    static let base = "https://rumble.com/service.php"

    static func get(_ name: String, _ params: [String: String] = [:]) -> URLRequest {
        var c = URLComponents(string: base)!
        c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "name", value: name)]
        var r = URLRequest(url: c.url!)
        r.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        // Never answer from the phone's cache: a cached comment list made deleted comments look like they were still there.
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    static func post(_ name: String, _ form: [String: String]) -> URLRequest {
        var c = URLComponents(string: base)!
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        var r = URLRequest(url: c.url!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("https://rumble.com", forHTTPHeaderField: "Origin")
        r.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        r.httpBody = Data(formEncode(form).utf8)
        return r
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }

    static func status() -> URLRequest { get("user.has_unread_notifications", ["api": "7"]) }
    static func notifications(limit: Int = 50) -> URLRequest { get("user.notification_feed", ["api": "7", "limit": "\(limit)"]) }
    static func comments(listID: String, sort: String? = nil) -> URLRequest {
        var p = ["video": listID]
        if let sort { p["sort"] = sort }
        return get("comment.list", p)
    }
    static func addComment(videoNumericID: String, text: String, replyTo: String?) -> URLRequest {
        var f = ["video": videoNumericID, "comment": text]
        if let replyTo { f["reply_id"] = replyTo }
        return post("comment.add", f)
    }
    /// vote: 1 like, -1 dislike, 0 clear. type 2 = comment, 1 = video.
    static func vote(contentID: String, type: Int, vote: Int) -> URLRequest {
        post("user.rumbles", ["type": "\(type)", "id": contentID, "vote": "\(vote)"])
    }
    static func deleteComment(_ id: String) -> URLRequest { get("comment.delete", ["comment_id": id]) }
    static func deleteCommentPost(_ id: String) -> URLRequest { post("comment.delete", ["comment_id": id]) }
    static func restoreComment(_ id: String) -> URLRequest { get("comment.restore", ["comment_id": id]) }

    /// "$$.user={username:"name",logged_in:true}" on any rumble.com page.
    static func username(fromPage html: String) -> String? {
        guard let r = html.range(of: #"\$\$\.user\s*=\s*\{\s*username\s*:\s*"([^"]*)""#, options: .regularExpression) else { return nil }
        let s = html[r]
        guard let q1 = s.range(of: "\"", options: .backwards, range: s.startIndex..<s.index(before: s.endIndex)) else { return nil }
        let name = String(s[q1.upperBound..<s.index(before: s.endIndex)])
        return name.isEmpty ? nil : name
    }

    /// Comment id from a service response like {"data":{"comment_id":123,...}} or an error message.
    static func parseResult(_ data: Data) -> Result<[String: Any], AccountError> {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.badResponse) }
        let d = obj["data"] as? [String: Any] ?? [:]
        if let e = d["error"] as? String, !e.isEmpty { return .failure(.server(e)) }
        if let e = d["error"] as? [String: Any], let m = e["message"] as? String { return .failure(.server(m)) }
        if let u = obj["user"] as? [String: Any], u["logged_in"] as? Bool == false { return .failure(.notLoggedIn) }
        return .success(d)
    }
}
