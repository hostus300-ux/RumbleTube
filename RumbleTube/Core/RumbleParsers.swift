import Foundation

/// What we can read from a watch page's HTML (server-rendered).
struct WatchPageInfo: Equatable {
    var embedId: String?
    var title: String?
    var description: String?
    var thumbnail: String?
    var uploadDate: Date?
    var duration: Double?
    var views: Int?
    var likes: String?
    var dislikes: String?
    var channelPath: String?
    var channelName: String?
    var channelFollowers: String?
    var channelVerified = false
    var channelJoinable = false
    var tipID: String?
}

/// The creator extras rumble.com shows next to Follow: the verified check, "Join" (memberships) and
/// "Tip" (a Rumble Wallet QR code, loaded from /-htmx/wallet/payment/qr-modal?eid=…).
enum CreatorExtras {
    static func tipID(_ html: String) -> String? {
        // hx-get="/-htmx/wallet/payment/qr-modal" … hx-vals='{"eid":"T1Ok2lc-9LU","dt":"c",…}'
        guard let r = html.range(of: "/-htmx/wallet/payment/qr-modal") else { return nil }
        let window = String(html[r.lowerBound...].prefix(1200))
        let pattern = #"(?:&quot;|")eid(?:&quot;|")\s*:\s*(?:&quot;|")([A-Za-z0-9_-]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)),
              let g = Range(m.range(at: 1), in: window) else { return nil }
        return String(window[g])
    }

    static func joinable(_ html: String) -> Bool { html.contains("locals-subscription-button") }

    static func qrModalURL(tipID: String) -> URL? {
        var c = URLComponents(string: "https://rumble.com/-htmx/wallet/payment/qr-modal")!
        c.queryItems = [URLQueryItem(name: "eid", value: tipID), URLQueryItem(name: "dt", value: "c"),
                        URLQueryItem(name: "trigger_id", value: "tips-button"), URLQueryItem(name: "theme", value: "dark")]
        return c.url
    }

    /// The QR image (a data: URL) from the tip modal's HTML.
    static func qrImageData(_ html: String) -> Data? {
        guard let r = html.range(of: #"src="data:image/png;base64,([^"]+)"[^>]*alt="QR Code""#, options: .regularExpression)
                ?? html.range(of: #"src="data:image/png;base64,([^"]+)""#, options: .regularExpression) else { return nil }
        let chunk = String(html[r])
        guard let a = chunk.range(of: "base64,"), let e = chunk[a.upperBound...].firstIndex(of: "\"") else { return nil }
        let b64 = String(chunk[a.upperBound..<e]).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: "")
        return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
    }
}

enum WatchPageParser {
    static func parse(_ html: String) -> WatchPageInfo {
        var info = WatchPageInfo()

        // JSON-LD VideoObject (standard schema.org data — the most stable source)
        for block in matches(html, #"<script[^>]*type=["']?application/ld\+json["']?[^>]*>([\s\S]*?)</script>"#) {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let objects: [[String: Any]] = (json as? [[String: Any]]) ?? [(json as? [String: Any]) ?? [:]]
            for obj in objects where (obj["@type"] as? String) == "VideoObject" {
                info.title = info.title ?? (obj["name"] as? String).map(HTMLText.decodeEntities)
                info.description = info.description ?? (obj["description"] as? String).map(HTMLText.decodeEntities)
                info.thumbnail = info.thumbnail ?? (obj["thumbnailUrl"] as? String)
                    ?? ((obj["thumbnailUrl"] as? [String])?.first)
                if let e = obj["embedUrl"] as? String { info.embedId = info.embedId ?? embedId(fromURL: e) }
                if let d = obj["uploadDate"] as? String { info.uploadDate = info.uploadDate ?? DateParsing.iso8601(d) }
                if let d = obj["duration"] as? String { info.duration = info.duration ?? TimeFormat.parseISODuration(d) }
                info.views = info.views ?? interactionCount(obj["interactionStatistic"])
                if let author = obj["author"] as? [String: Any] {
                    info.channelName = info.channelName ?? (author["name"] as? String)
                    if let u = author["url"] as? String { info.channelPath = info.channelPath ?? RumbleURL.channelPath(from: u) }
                }
            }
        }

        // Fallbacks / extras from markup (patterns used by yt-dlp)
        if info.embedId == nil, let e = first(html, #"["']embedUrl["']\s*:\s*["']([^"']+)["']"#) {
            info.embedId = embedId(fromURL: e)
        }
        if info.embedId == nil, let e = first(html, #"https?://(?:www\.)?rumble\.com/embed/([0-9a-z.]+)"#) {
            info.embedId = embedId(fromURL: "https://rumble.com/embed/\(e)/")
        }
        if info.views == nil, let v = first(html, #""userInteractionCount"\s*:\s*"?(\d+)"#) { info.views = Int(v) }
        info.channelVerified = html.contains("media-heading-verified")
        info.channelJoinable = CreatorExtras.joinable(html)
        info.tipID = CreatorExtras.tipID(html)
        info.likes = first(html, #"<span data-js="rumbles_up_votes">\s*([\d,.KMB]+)"#)
        info.dislikes = first(html, #"<span data-js="rumbles_down_votes">\s*([\d,.KMB]+)"#)
        // The full description is split into a visible first paragraph and "show more" paragraphs
        // (<p class="media-description media-description--first|--more">); JSON-LD cuts it at 200 characters.
        let parts = matches(html, #"<p class="media-description[^"]*"[^>]*>([\s\S]*?)</p>"#)
            // drop the page's own "Show more" / "Show less" buttons
            .map { $0.replacingOccurrences(of: #"<button[\s\S]*?</button>"#, with: "", options: .regularExpression) }
            .map { HTMLText.plain($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty {
            let text = parts.joined(separator: "\n\n")
            if text.count > (info.description?.count ?? 0) { info.description = text }
        } else if let d = first(html, #"class="[^"]*media-description[^"]*"[^>]*>([\s\S]*?)</(?:div|p)>\s*(?:<button|</div>|<div)"#) {
            let text = HTMLText.plain(d)
            if text.count > (info.description?.count ?? 0) { info.description = text }
        }
        if info.channelPath == nil, let p = first(html, #"class="[^"]*media-by--a[^"]*"[^>]*href="([^"]+)""#)
            ?? first(html, #"href="([^"]+)"[^>]*class="[^"]*media-by--a"#) {
            info.channelPath = RumbleURL.channelPath(from: p)
        }
        info.channelFollowers = first(html, #"([\d.,]+\s*[KMB]?)\s+(?:Followers|followers)"#)?
            .replacingOccurrences(of: " ", with: "")
        return info
    }

    /// "https://rumble.com/embed/v5abc12/" or ".../embed/u4.v5abc12/" → "v5abc12"
    static func embedId(fromURL s: String) -> String? {
        guard let r = s.range(of: #"/embed/(?:[0-9a-z]+\.)?([0-9a-z]+)"#, options: .regularExpression) else { return nil }
        let tail = s[r].split(separator: "/").last.map(String.init) ?? ""
        return tail.split(separator: ".").last.map(String.init)
    }

    private static func interactionCount(_ v: Any?) -> Int? {
        if let d = v as? [String: Any] {
            if let n = d["userInteractionCount"] as? Int { return n }
            if let s = d["userInteractionCount"] as? String { return Int(s) }
        }
        if let arr = v as? [[String: Any]] { return arr.lazy.compactMap { interactionCount($0) }.first }
        return nil
    }

    // MARK: regex helpers
    static func first(_ s: String, _ pattern: String) -> String? { matches(s, pattern).first }

    static func matches(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
    }
}

/// Response of https://rumble.com/embedJS/u3/?request=video&ver=2&v=<embedId>
struct EmbedInfo: Equatable {
    var title: String?
    var duration: Double?
    var published: Date?
    var authorName: String?
    var authorURL: String?
    var thumbnail: String?
    var liveStatus: LiveStatus
    var streams: [StreamOption]
    var message: String?
}

enum EmbedParser {
    static func parse(_ data: Data) -> EmbedInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var streams: [StreamOption] = []
        if let ua = obj["ua"] as? [String: Any] {
            for (type, value) in ua {
                let kind: StreamKind
                switch type {
                case "hls": kind = .hls
                case "mp4": kind = .mp4
                default: continue // webm (not playable by AVPlayer), tar, timeline, audio
                }
                var entries: [(String?, [String: Any])] = []
                if let dict = value as? [String: Any] {
                    for (k, v) in dict { if let d = v as? [String: Any] { entries.append((k, d)) } }
                } else if let arr = value as? [[String: Any]] {
                    entries = arr.map { (nil, $0) }
                }
                for (key, info) in entries {
                    guard let url = info["url"] as? String, !url.isEmpty else { continue }
                    let meta = info["meta"] as? [String: Any] ?? [:]
                    let h = int(meta["h"]) ?? key.flatMap { Int($0) }
                    streams.append(StreamOption(kind: kind, height: h, bitrate: int(meta["bitrate"]), url: url))
                }
            }
        }
        // stable order: HLS first, then MP4 by height desc; drop duplicate URLs
        var seen = Set<String>()
        streams = streams.filter { seen.insert($0.url).inserted }.sorted {
            if $0.kind != $1.kind { return $0.kind == .hls }
            return ($0.height ?? 0) > ($1.height ?? 0)
        }

        let live: LiveStatus
        switch int(obj["live"]) {
        case 2: live = .isLive
        case 1: live = obj["livestream_has_dvr"] != nil && !(obj["livestream_has_dvr"] is NSNull) ? .upcoming : .wasLive
        default: live = .notLive
        }
        let author = obj["author"] as? [String: Any]
        var thumb = obj["i"] as? String
        if let t = obj["t"] as? [[String: Any]], let best = t.max(by: { (int($0["w"]) ?? 0) < (int($1["w"]) ?? 0) }),
           let u = best["i"] as? String { thumb = u }
        let msg = (obj["sys"] as? [String: Any])?["msg"] as? String

        return EmbedInfo(
            title: (obj["title"] as? String).map(HTMLText.decodeEntities),
            duration: live == .isLive ? nil : double(obj["duration"]),
            published: (obj["pubDate"] as? String).flatMap(DateParsing.iso8601),
            authorName: author?["name"] as? String,
            authorURL: author?["url"] as? String,
            thumbnail: thumb,
            liveStatus: live,
            streams: streams,
            message: msg)
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
    private static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

enum VideoDetailBuilder {
    static func build(id: String, url: String, page: WatchPageInfo, embed: EmbedInfo, embedId: String) -> VideoDetail {
        var channel: ChannelRef?
        let path = page.channelPath ?? embed.authorURL.flatMap(RumbleURL.channelPath(from:))
        if let p = path { channel = ChannelRef(path: p, name: page.channelName ?? embed.authorName ?? p, avatar: nil) }
        return VideoDetail(
            id: id, url: url, embedId: embedId,
            title: embed.title ?? page.title ?? "Untitled",
            description: page.description,
            thumbnail: page.thumbnail ?? embed.thumbnail,
            duration: embed.duration ?? page.duration,
            published: embed.published ?? page.uploadDate,
            views: page.views, likes: page.likes, dislikes: page.dislikes,
            channel: channel, channelFollowers: page.channelFollowers,
            liveStatus: embed.liveStatus, streams: embed.streams,
            channelVerified: page.channelVerified, channelJoinable: page.channelJoinable, tipID: page.tipID)
    }
}
