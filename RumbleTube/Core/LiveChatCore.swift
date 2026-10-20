import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One live-chat message (regular or rant).
struct ChatMessage: Identifiable, Hashable {
    var id: String
    var time: Date?
    var userID: String
    var username: String
    var avatar: String?
    var color: String?
    var badges: [String]
    var text: String
    /// Paid "rant" amount in cents, if any.
    var rantCents: Int?
    var isChannel: Bool
}

struct ChatConfig: Hashable {
    var apiBase: String     // e.g. https://web7.rumble.com/chat/api
    var chatID: String      // the video's numeric id
    /// Where paid rants are posted (Rumble's second RumbleChat argument).
    var rantsBase: String? = nil
    var rantLevels: [RantLevel] = RantLevel.defaults
}

/// A rant price tier: dollars and how long it stays pinned.
struct RantLevel: Hashable, Identifiable {
    var dollars: Int
    var seconds: Int
    var id: Int { dollars }
    var cents: Int { dollars * 100 }

    static let defaults: [RantLevel] = [[1, 120], [2, 180], [5, 300], [10, 600], [20, 1200], [50, 2400],
                                        [100, 3600], [200, 7200], [300, 10800], [400, 14400], [500, 18000]]
        .map { RantLevel(dollars: $0[0], seconds: $0[1]) }

    /// Rumble's tier colours ($1 blue … $100+ red) as hex, and whether text on it should be dark.
    var colorHex: UInt32 {
        switch dollars {
        case ..<2: return 0x4A90E2
        case ..<5: return 0xB8E986
        case ..<10: return 0xF8E71C
        case ..<20: return 0xF5A623
        case ..<50: return 0xBD10E0
        case ..<100: return 0x9013FE
        default: return 0xD0021B
        }
    }
    var darkText: Bool { (2..<20).contains(dollars) }

    var durationText: String {
        seconds >= 3600 ? "\(seconds / 3600) hour\(seconds >= 7200 ? "s" : "")" : "\(seconds / 60) minutes"
    }
}

/// Parses Rumble's live chat: the watch page config and the server-sent-event stream.
enum LiveChatParser {
    /// `RumbleChat("https://web7.rumble.com/chat/api", "https://…/chat/api", 448347576, …)` on the watch page.
    static func config(fromWatchPage html: String) -> ChatConfig? {
        let pattern = #"RumbleChat\(\s*"([^"]+)"\s*,\s*"([^"]*)"\s*,\s*(\d+)\s*,\s*\d+\s*,\s*(\[\[[\d,\[\]\s]*\]\])?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let api = Range(m.range(at: 1), in: html), let id = Range(m.range(at: 3), in: html) else { return nil }
        var c = ChatConfig(apiBase: String(html[api]), chatID: String(html[id]))
        if let r = Range(m.range(at: 2), in: html), !html[r].isEmpty { c.rantsBase = String(html[r]) }
        if let r = Range(m.range(at: 4), in: html),
           let arr = try? JSONSerialization.jsonObject(with: Data(html[r].utf8)) as? [[Int]] {
            let levels = arr.compactMap { $0.count >= 2 ? RantLevel(dollars: $0[0], seconds: $0[1]) : nil }
            if !levels.isEmpty { c.rantLevels = levels }
        }
        return c
    }

    static func streamURL(_ c: ChatConfig) -> URL { URL(string: "\(c.apiBase)/chat/\(c.chatID)/stream")! }

    /// Event type plus any messages it carries ("init" and "messages" both carry messages/users/channels).
    static func parseEvent(_ json: Data) -> (type: String, messages: [ChatMessage], deletedIDs: [String])? {
        guard let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        let d = obj["data"] as? [String: Any] ?? [:]
        var people: [String: (name: String, avatar: String?, color: String?, badges: [String], channel: Bool)] = [:]
        for u in d["users"] as? [[String: Any]] ?? [] {
            guard let id = str(u["id"]) else { continue }
            people[id] = (u["username"] as? String ?? "user", u["image.1"] as? String, u["color"] as? String,
                          u["badges"] as? [String] ?? [], false)
        }
        for c in d["channels"] as? [[String: Any]] ?? [] {
            guard let id = str(c["id"]) else { continue }
            people["c" + id] = (c["username"] as? String ?? "channel", c["image.1"] as? String, nil, [], true)
        }
        let msgs: [ChatMessage] = (d["messages"] as? [[String: Any]] ?? []).compactMap { m in
            guard let id = str(m["id"]) else { return nil }
            let uid = str(m["user_id"]) ?? ""
            let who = str(m["channel_id"]).flatMap { people["c" + $0] } ?? people[uid]
            let rant = m["rant"] as? [String: Any]
            return ChatMessage(id: id, time: (m["time"] as? String).flatMap(DateParsing.iso8601), userID: uid,
                               username: who?.name ?? "user", avatar: who?.avatar, color: who?.color,
                               badges: who?.badges ?? [], text: HTMLText.decodeEntities(m["text"] as? String ?? ""),
                               rantCents: rant.flatMap { RumbleJSON.int($0["price_cents"]) },
                               isChannel: who?.channel ?? false)
        }
        let deleted = (d["message_ids"] as? [Any] ?? []).compactMap(str)
        return (type, msgs, deleted)
    }

    /// POST body for sending a message (same shape Rumble's web chat sends).
    static func sendRequest(_ c: ChatConfig, text: String, requestID: String = UUID().uuidString) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(c.apiBase)/chat/\(c.chatID)/message")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("https://rumble.com", forHTTPHeaderField: "Origin")
        r.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        let body: [String: Any] = ["data": ["request_id": requestID, "message": ["text": text],
                                            "rant": NSNull(), "channel_id": NSNull()]]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// Paid rant from the signed-in user's Rumble Wallet (same request Rumble's web chat sends).
    static func rantRequest(_ c: ChatConfig, text: String, cents: Int, requestID: String = UUID().uuidString) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(c.rantsBase ?? c.apiBase)/chat/\(c.chatID)/message")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("https://rumble.com", forHTTPHeaderField: "Origin")
        r.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        let body: [String: Any] = ["data": ["request_id": requestID, "message": ["text": text],
                                            "rant": ["payment_type": "rumble-wallet", "price_cents": cents],
                                            "channel_id": NSNull()]]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    private static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let i = v as? Int { return String(i) }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}

// MARK: - Emotes (Rumble's own images, e.g. :r+rumblecharge: or channel/subscriber emotes)

struct ChatEmote: Hashable {
    var name: String          // "r+rumblecharge"
    var url: String           // png / gif
    var subsOnly: Bool
}

enum ChatSegment: Hashable {
    case text(String)
    case emote(ChatEmote)
}

enum ChatEmotes {
    /// `service.php?name=emote.list&chat_id=<id>` (signed-in: includes channels you subscribe to).
    static func request(chatID: String) -> URLRequest {
        var c = URLComponents(string: "https://rumble.com/service.php")!
        c.queryItems = [URLQueryItem(name: "name", value: "emote.list"), URLQueryItem(name: "chat_id", value: chatID)]
        var r = URLRequest(url: c.url!)
        r.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        return r
    }

    /// Accepts `{data:{items:[…]}}` or `{items:[…]}`; each item is a pack with `emotes:[{name,file,is_subs_only}]`.
    static func parse(_ data: Data) -> [String: ChatEmote] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        let packs = ((obj["data"] as? [String: Any])?["items"] ?? obj["items"]) as? [[String: Any]] ?? []
        var out: [String: ChatEmote] = [:]
        for p in packs {
            for e in p["emotes"] as? [[String: Any]] ?? [] {
                guard let name = e["name"] as? String, let file = e["file"] as? String, !file.isEmpty else { continue }
                out[name.lowercased()] = ChatEmote(name: name, url: file, subsOnly: e["is_subs_only"] as? Bool ?? false)
            }
        }
        return out
    }

    /// Split a message into text and emote pieces (Rumble writes emotes as `:name:`).
    static func segments(_ text: String, emotes: [String: ChatEmote]) -> [ChatSegment] {
        guard !emotes.isEmpty, text.contains(":"),
              let re = try? NSRegularExpression(pattern: #":([a-z0-9_]+(?:\+[a-z0-9_]+)?):"#, options: .caseInsensitive)
        else { return [.text(text)] }
        let ns = text as NSString
        var out: [ChatSegment] = []
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let e = emotes[ns.substring(with: m.range(at: 1)).lowercased()] else { continue }
            if m.range.location > last { out.append(.text(ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
            out.append(.emote(e))
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(.text(ns.substring(from: last))) }
        return out.isEmpty ? [.text(text)] : out
    }
}
