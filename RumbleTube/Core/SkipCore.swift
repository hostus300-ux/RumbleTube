import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Categories & settings

enum SkipCategory: String, Codable, CaseIterable, Identifiable {
    case sponsor, selfpromo, interaction, intro, outro, preview, filler
    case musicOfftopic = "music_offtopic"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sponsor: return "Sponsor"
        case .selfpromo: return "Self-promotion"
        case .interaction: return "Like/subscribe ask"
        case .intro: return "Intro"
        case .outro: return "Outro / credits"
        case .preview: return "Preview / recap"
        case .filler: return "Filler tangent"
        case .musicOfftopic: return "Non-music section"
        }
    }

    /// Hex colour, same as SponsorBlock.
    var hex: UInt32 {
        switch self {
        case .sponsor: return 0x00D400
        case .selfpromo: return 0xFFFF00
        case .interaction: return 0xCC00FF
        case .intro: return 0x00FFFF
        case .outro: return 0x0202ED
        case .preview: return 0x008FD6
        case .filler: return 0x7300FF
        case .musicOfftopic: return 0xFF9900
        }
    }

    var defaultAction: SkipAction {
        switch self {
        case .sponsor, .selfpromo, .interaction: return .skip
        case .intro, .outro, .preview: return .button
        case .filler, .musicOfftopic: return .off
        }
    }
}

enum SkipAction: String, Codable, CaseIterable, Identifiable {
    case skip, button, off
    var id: String { rawValue }
    var name: String {
        switch self {
        case .skip: return "Auto skip"
        case .button: return "Show skip button"
        case .off: return "Ignore"
        }
    }
}

struct SkipSettings: Codable, Equatable {
    var serverURL: String = ""
    var actions: [String: SkipAction] = [:]
    var useYouTubeLinks: Bool = true
    var showNotice: Bool = true
    var userID: String = SkipSettings.randomID()

    func action(for c: SkipCategory) -> SkipAction { actions[c.rawValue] ?? c.defaultAction }

    var server: String? {
        let s = serverURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return s.isEmpty ? nil : s
    }

    static func randomID() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<24).map { _ in chars.randomElement()! })
    }
}

// MARK: - Segments

enum SegmentSource: String, Codable { case local, server, youtube

    var rank: Int { self == .local ? 3 : self == .server ? 2 : 1 }
}

struct SkipSegment: Codable, Hashable, Identifiable {
    var uuid: String
    var start: Double
    var end: Double
    var category: SkipCategory
    var source: SegmentSource
    var votes: Int = 0
    var videoDuration: Double?
    var id: String { uuid }
}

struct YouTubeLink: Codable, Hashable {
    var uuid: String
    var youtubeID: String
    var offset: Double
    var votes: Int
    var local: Bool
}

// MARK: - Engine (pure logic, mirrors the browser extension)

enum SkipEngine {
    /// Usable segments: drop wrong-length videos (ads, other edits) and overlapping duplicates.
    static func resolve(_ all: [SkipSegment], videoDuration: Double?) -> [SkipSegment] {
        let usable = all.filter { s in
            guard s.end > s.start else { return false }
            if let d = videoDuration, d.isFinite, d > 0 {
                if s.start >= d { return false }
                if s.source != .youtube, let sd = s.videoDuration, sd > 0 {
                    let tol = max(3, d * 0.02)
                    if abs(sd - d) > tol { return false }
                }
            }
            return true
        }.sorted { a, b in
            a.source.rank != b.source.rank ? a.source.rank > b.source.rank : a.votes > b.votes
        }
        var out: [SkipSegment] = []
        for s in usable where !out.contains(where: { $0.category == s.category && overlap($0, s) > 0.5 }) {
            out.append(s)
        }
        return out.sorted { $0.start < $1.start }
    }

    static func overlap(_ a: SkipSegment, _ b: SkipSegment) -> Double {
        let inter = max(0, min(a.end, b.end) - max(a.start, b.start))
        let shorter = min(a.end - a.start, b.end - b.start)
        return shorter > 0 ? inter / shorter : 0
    }

    static func active(_ segs: [SkipSegment], at t: Double, settings: SkipSettings,
                       ignored: Set<String>) -> (SkipSegment, SkipAction)? {
        for s in segs {
            let act = settings.action(for: s.category)
            if act == .off || ignored.contains(s.uuid) { continue }
            if t >= s.start && t < s.end - 0.25 { return (s, act) }
        }
        return nil
    }

    static func autoSkipStarts(_ segs: [SkipSegment], settings: SkipSettings, ignored: Set<String>) -> [Double] {
        segs.filter { settings.action(for: $0.category) == .skip && !ignored.contains($0.uuid) }.map(\.start)
    }

    static func parseYouTubeID(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil { return s }
        guard let r = s.range(of: #"(?:v=|youtu\.be/|/shorts/|/embed/|/live/)[A-Za-z0-9_-]{11}"#, options: .regularExpression)
        else { return nil }
        return String(s[r].suffix(11))
    }
}

// MARK: - Network client (RumbleSkip server + SponsorBlock)

struct SkipFetchResult {
    var segments: [SkipSegment] = []
    var links: [YouTubeLink] = []
    var errors: [String] = []
}

enum SkipError: Error, LocalizedError {
    case noServer, http(Int, String?)
    var errorDescription: String? {
        switch self {
        case .noServer: return "No community server set"
        case .http(let code, let msg): return msg ?? "Server error \(code)"
        }
    }
}

struct SkipClient {
    var settings: SkipSettings
    var session: URLSession = .shared
    static let sponsorBlockAPI = "https://sponsor.ajay.app/api/skipSegments"

    /// Server segments + links for a video (privacy-preserving 4-char hash prefix lookup).
    func fetchServer(videoID: String) async throws -> ([SkipSegment], [YouTubeLink]) {
        guard let server = settings.server else { return ([], []) }
        let prefix = String(SHA256.hex(videoID).prefix(4))
        let (data, code) = try await get("\(server)/api/segments/\(prefix)")
        guard code == 200 else { throw SkipError.http(code, nil) }
        return Self.decodeServer(data, videoID: videoID)
    }

    static func decodeServer(_ data: Data, videoID: String) -> ([SkipSegment], [YouTubeLink]) {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let entry = arr.first(where: { ($0["videoID"] as? String) == videoID }) else { return ([], []) }
        let segs: [SkipSegment] = (entry["segments"] as? [[String: Any]] ?? []).compactMap { s in
            guard let uuid = s["UUID"] as? String, let seg = s["segment"] as? [Double], seg.count == 2,
                  let cat = SkipCategory(rawValue: s["category"] as? String ?? "") else { return nil }
            return SkipSegment(uuid: uuid, start: seg[0], end: seg[1], category: cat, source: .server,
                               votes: s["votes"] as? Int ?? 0, videoDuration: s["videoDuration"] as? Double)
        }
        let links: [YouTubeLink] = (entry["links"] as? [[String: Any]] ?? []).compactMap { l in
            guard let uuid = l["UUID"] as? String, let yt = l["youtubeID"] as? String else { return nil }
            return YouTubeLink(uuid: uuid, youtubeID: yt, offset: (l["offset"] as? Double) ?? 0,
                               votes: l["votes"] as? Int ?? 0, local: false)
        }
        return (segs, links)
    }

    /// SponsorBlock segments for the linked YouTube video, shifted onto the Rumble timeline.
    func fetchSponsorBlock(youtubeID: String, offset: Double) async throws -> [SkipSegment] {
        let cats = SkipCategory.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        var c = URLComponents(string: Self.sponsorBlockAPI)!
        c.queryItems = [URLQueryItem(name: "videoID", value: youtubeID), URLQueryItem(name: "categories", value: "[\(cats)]")]
        let (data, code) = try await get(c.url!.absoluteString)
        if code == 404 { return [] }
        guard code == 200 else { throw SkipError.http(code, nil) }
        return Self.decodeSponsorBlock(data, offset: offset)
    }

    static func decodeSponsorBlock(_ data: Data, offset: Double) -> [SkipSegment] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.compactMap { s in
            guard let uuid = s["UUID"] as? String, let seg = s["segment"] as? [Double], seg.count == 2,
                  let cat = SkipCategory(rawValue: s["category"] as? String ?? ""),
                  (s["actionType"] as? String ?? "skip") == "skip" else { return nil }
            let a = max(0, seg[0] + offset), b = seg[1] + offset
            guard b > a else { return nil }
            return SkipSegment(uuid: "yt:\(uuid)", start: a, end: b, category: cat, source: .youtube,
                               votes: s["votes"] as? Int ?? 0, videoDuration: s["videoDuration"] as? Double)
        }
    }

    struct SubmitResult { var uuid: String; var duplicate: Bool }

    func submit(videoID: String, videoDuration: Double, start: Double, end: Double,
                category: SkipCategory) async throws -> SubmitResult {
        guard let server = settings.server else { throw SkipError.noServer }
        let body: [String: Any] = [
            "videoID": videoID, "userID": settings.userID, "videoDuration": videoDuration,
            "segments": [["segment": [start, end], "category": category.rawValue]],
        ]
        let (data, code) = try await post("\(server)/api/segments", body)
        guard code == 200, let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let first = arr.first, let uuid = first["UUID"] as? String
        else { throw SkipError.http(code, Self.errorMessage(data)) }
        return SubmitResult(uuid: uuid, duplicate: first["duplicate"] as? Bool ?? false)
    }

    /// type: 1 up, 0 undo, -1 down. Returns true when the server removed the user's own segment.
    @discardableResult
    func vote(uuid: String, type: Int, kind: String = "segment") async throws -> Bool {
        guard let server = settings.server else { throw SkipError.noServer }
        let (data, code) = try await post("\(server)/api/vote",
                                          ["userID": settings.userID, "UUID": uuid, "type": type, "kind": kind])
        guard code == 200 else { throw SkipError.http(code, Self.errorMessage(data)) }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["removed"] as? Bool ?? false
    }

    func shareLink(videoID: String, youtubeID: String, offset: Double) async throws {
        guard let server = settings.server else { throw SkipError.noServer }
        let (data, code) = try await post("\(server)/api/links", [
            "videoID": videoID, "userID": settings.userID, "youtubeID": youtubeID, "offset": offset,
        ])
        guard code == 200 else { throw SkipError.http(code, Self.errorMessage(data)) }
    }

    func reportViewed(uuid: String) async {
        guard let server = settings.server else { return }
        _ = try? await post("\(server)/api/viewed", ["UUID": uuid])
    }

    // MARK: http
    private func get(_ url: String) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func post(_ url: String, _ body: [String: Any]) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func errorMessage(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
    }
}

// MARK: - SHA-256 (small, dependency-free; used for the hash-prefix lookup)

enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ string: String) -> String {
        digest(Array(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = message
        let bitLen = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }

        @inline(__always) func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).map { UInt8((v >> (24 - UInt32($0) * 8)) & 0xff) } }
    }
}
