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
}

/// Parses Rumble's live chat: the watch page config and the server-sent-event stream.
enum LiveChatParser {
    /// `RumbleChat("https://web7.rumble.com/chat/api", "https://…/chat/api", 448347576, …)` on the watch page.
    static func config(fromWatchPage html: String) -> ChatConfig? {
        let pattern = #"RumbleChat\(\s*"([^"]+)"\s*,\s*"[^"]*"\s*,\s*(\d+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let api = Range(m.range(at: 1), in: html), let id = Range(m.range(at: 2), in: html) else { return nil }
        return ChatConfig(apiBase: String(html[api]), chatID: String(html[id]))
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

    private static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let i = v as? Int { return String(i) }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}
