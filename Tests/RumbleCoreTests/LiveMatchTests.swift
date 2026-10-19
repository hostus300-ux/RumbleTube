import XCTest
@testable import RumbleCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live check against real YouTube/SponsorBlock. Runs only with LIVE_YT=<path to samples.json>.
final class LiveMatchTests: XCTestCase {
    func testLiveMatching() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIVE_YT"] else { throw XCTSkip("set LIVE_YT") }
        let samples = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: String]]
        for s in samples {
            let title = s["title"]!, channel = s["channel"]!, dur = TimeFormat.parseClock(s["duration"]!)
            let req = YouTubeMatcher.searchRequest(YouTubeMatcher.query(title: title, channel: YouTubeMatcher.cleanChannel(channel)))
            let html: String
            var data = Data(); var resp: URLResponse?
            if let dir = ProcessInfo.processInfo.environment["LIVE_CACHE"] {
                html = (try? String(contentsOfFile: "\(dir)/\(s["id"]!).html")) ?? ""
            } else {
                guard let r = try? await URLSession.shared.data(for: req) else { print("FETCH FAIL \(title.prefix(40))"); continue }
                data = r.0; resp = r.1
                html = String(decoding: data, as: UTF8.self)
            }
            let cands = YouTubeMatcher.parseSearch(html)
            if ProcessInfo.processInfo.environment["DEBUG_YT"] != nil {
                print("  q=\(req.url!.absoluteString.prefix(160)) status=\((resp as? HTTPURLResponse)?.statusCode ?? 0) bytes=\(data.count)")
                for c in cands.prefix(4) {
                    print("    · \(c.title.prefix(60)) [\(c.channel)] \(c.duration.map { TimeFormat.clock($0) } ?? "?") t=\(String(format: "%.2f", YouTubeMatcher.titleSimilarity(title, c.title))) c=\(String(format: "%.2f", YouTubeMatcher.channelSimilarity(channel, c.channel)))")
                }
            }
            let m = YouTubeMatcher.bestMatch(title: title, channel: channel, duration: dur, candidates: cands)
            var sb = "-"
            if ProcessInfo.processInfo.environment["LIVE_CACHE"] != nil { sb = m?.candidate.videoID ?? "-" }
            else if let m, let r = try? await URLSession.shared.data(from: URL(string: "https://sponsor.ajay.app/api/skipSegments?videoID=\(m.candidate.videoID)")!) {
                sb = (r.1 as? HTTPURLResponse)?.statusCode == 200 ? "\(((try? JSONSerialization.jsonObject(with: r.0)) as? [Any])?.count ?? 0) segs" : "0 segs"
            }
            let verdict = m == nil ? "NONE" : m!.confidence.rawValue.uppercased()
            print("[\(s["truth"]!)] \(verdict) \(cands.count)c | \(title.prefix(55)) -> \(m.map { "\($0.candidate.title.prefix(55)) [\($0.candidate.channel)] t=\(String(format: "%.2f", $0.titleScore)) c=\(String(format: "%.2f", $0.channelScore)) Δ=\($0.durationDiff.map { String(Int($0)) } ?? "?")s" } ?? "") | SB \(sb)")
            if ProcessInfo.processInfo.environment["LIVE_CACHE"] == nil { try await Task.sleep(nanoseconds: 700_000_000) }
        }
    }
}
