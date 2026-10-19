import XCTest
@testable import RumbleCore

final class RumbleCoreTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: URLs & formatting
    func testVideoIdFromURLs() {
        XCTAssertEqual(RumbleURL.videoId(from: "https://rumble.com/v6abc12-some-title.html?e9s=x"), "v6abc12")
        XCTAssertEqual(RumbleURL.videoId(from: "/V4XYZ9-Title.html"), "v4xyz9")
        XCTAssertNil(RumbleURL.videoId(from: "https://rumble.com/c/Redacted"))
        XCTAssertEqual(RumbleURL.videoId(from: "https://rumble.com/shorts/v7GRK6e"), "v7grk6e")
        XCTAssertEqual(RumbleURL.clean("https://rumble.com/v6abc12-t.html?e9s=src&sci=1"), "https://rumble.com/v6abc12-t.html")
        XCTAssertEqual(RumbleURL.clean("/v6abc12-t.html?x=1"), "https://rumble.com/v6abc12-t.html")
        XCTAssertEqual(RumbleURL.channelPath(from: "https://rumble.com/c/Redacted?e9s=x"), "/c/Redacted")
        XCTAssertEqual(RumbleURL.channelPath(from: "/user/Someone/videos"), "/user/Someone")
    }

    func testTimeFormatting() {
        XCTAssertEqual(TimeFormat.parseClock("1:02:44"), 3764)
        XCTAssertEqual(TimeFormat.parseClock("12:01"), 721)
        XCTAssertNil(TimeFormat.parseClock("LIVE"))
        XCTAssertEqual(TimeFormat.clock(3725), "1:02:05")
        XCTAssertEqual(TimeFormat.clock(65.9), "1:05")
        XCTAssertEqual(TimeFormat.precise(65.25), "1:05.2")
        XCTAssertEqual(TimeFormat.parseISODuration("PT00H14M52S"), 892)
        XCTAssertEqual(TimeFormat.parseISODuration("PT1H2M3.5S"), 3723.5)
        XCTAssertNil(TimeFormat.parseISODuration("garbage"))
        XCTAssertEqual(CountFormat.parse("1.81K"), 1810)
        XCTAssertEqual(CountFormat.parse("2,345"), 2345)
        XCTAssertEqual(CountFormat.short(152_340), "152K")
        XCTAssertEqual(CountFormat.short(1_500_000), "1.5M")
        XCTAssertEqual(HTMLText.plain("A &amp; B<br>C &#8217;d"), "A & B\nC ’d")
        XCTAssertNotNil(DateParsing.iso8601("2026-10-16T14:24:34-04:00"))
        XCTAssertNotNil(DateParsing.iso8601("2023-03-22T00:30:10+00:00"))
    }

    // MARK: Rumble parsers
    func testWatchPage() throws {
        let html = String(decoding: try fixture("watch.html"), as: UTF8.self)
        let p = WatchPageParser.parse(html)
        XCTAssertEqual(p.embedId, "v2bou5f")
        XCTAssertEqual(p.title, "The U.S. CANNOT hide this in Ukraine anymore | Redacted & Clayton")
        XCTAssertEqual(p.duration, 892)
        XCTAssertEqual(p.views, 152340)
        XCTAssertEqual(p.likes, "2.1K")
        XCTAssertEqual(p.dislikes, "31")
        XCTAssertEqual(p.channelPath, "/c/Redacted")
        XCTAssertEqual(p.channelFollowers, "697K")
        XCTAssertEqual(p.description, "Full description with a link & more.\nSecond line.")
        XCTAssertNotNil(p.uploadDate)
        XCTAssertEqual(WatchPageParser.embedId(fromURL: "https://rumble.com/embed/u4.v5abc12/?pub=4"), "v5abc12")
    }

    func testEmbedVOD() throws {
        let e = try XCTUnwrap(EmbedParser.parse(try fixture("embed.json")))
        XCTAssertEqual(e.liveStatus, .notLive)
        XCTAssertEqual(e.duration, 892)
        XCTAssertEqual(e.authorURL, "https://rumble.com/c/Redacted")
        XCTAssertEqual(e.thumbnail, "https://sp.rmbl.ws/s8/1/big.jpg")
        XCTAssertEqual(e.streams.map(\.label), ["Auto", "1080p", "720p", "360p"], "HLS first, mp4 by height, no webm/tar/timeline")
        let detail = VideoDetailBuilder.build(id: "v2ea9qb", url: "https://rumble.com/v2ea9qb-x.html",
                                              page: WatchPageParser.parse(String(decoding: try fixture("watch.html"), as: UTF8.self)),
                                              embed: e, embedId: "v2bou5f")
        XCTAssertEqual(detail.defaultStream?.kind, .hls)
        XCTAssertEqual(detail.channel?.path, "/c/Redacted")
        XCTAssertEqual(detail.channel?.name, "Redacted News")
        XCTAssertEqual(detail.title, "The U.S. CANNOT hide this in Ukraine anymore | Redacted with Natali and Clayton Morris")
    }

    func testEmbedLive() throws {
        let e = try XCTUnwrap(EmbedParser.parse(try fixture("embed-live.json")))
        XCTAssertEqual(e.liveStatus, .isLive)
        XCTAssertNil(e.duration)
        XCTAssertEqual(e.streams.count, 1)
        XCTAssertEqual(e.streams[0].kind, .hls)
    }

    func testDefaultStreamWithoutHLS() {
        let d = VideoDetail(id: "v", url: "u", embedId: "e", title: "t", liveStatus: .notLive, streams: [
            StreamOption(kind: .mp4, height: 2160, url: "a"), StreamOption(kind: .mp4, height: 720, url: "b"),
            StreamOption(kind: .mp4, height: 1080, url: "c"),
        ])
        XCTAssertEqual(d.defaultStream?.url, "c")
    }

    // MARK: Skip engine
    func seg(_ id: String, _ a: Double, _ b: Double, _ c: SkipCategory, _ src: SegmentSource,
             votes: Int = 0, dur: Double = 600) -> SkipSegment {
        SkipSegment(uuid: id, start: a, end: b, category: c, source: src, votes: votes, videoDuration: dur)
    }

    func testResolve() {
        var out = SkipEngine.resolve([seg("a", 10, 20, .sponsor, .server), seg("b", 30, 40, .sponsor, .server, dur: 45),
                                      seg("c", 50, 60, .intro, .youtube, dur: 590)], videoDuration: 600)
        XCTAssertEqual(out.map(\.uuid), ["a", "c"])
        out = SkipEngine.resolve([seg("yt", 10, 20, .sponsor, .youtube, votes: 50), seg("s1", 11, 21, .sponsor, .server, votes: 1),
                                  seg("s2", 10, 19, .sponsor, .server, votes: 5), seg("l", 12, 20, .sponsor, .local)], videoDuration: 600)
        XCTAssertEqual(out.map(\.uuid), ["l"])
        out = SkipEngine.resolve([seg("a", 0, 30, .intro, .server), seg("b", 10, 20, .sponsor, .server)], videoDuration: 600)
        XCTAssertEqual(out.count, 2)
    }

    func testActiveAndStarts() {
        var settings = SkipSettings()
        settings.actions = ["filler": .off]
        let segs = [seg("a", 10, 20, .sponsor, .server), seg("b", 30, 40, .intro, .server), seg("c", 50, 60, .filler, .server)]
        XCTAssertEqual(SkipEngine.active(segs, at: 15, settings: settings, ignored: [])?.1, .skip)
        XCTAssertEqual(SkipEngine.active(segs, at: 35, settings: settings, ignored: [])?.1, .button)
        XCTAssertNil(SkipEngine.active(segs, at: 55, settings: settings, ignored: []))
        XCTAssertNil(SkipEngine.active(segs, at: 15, settings: settings, ignored: ["a"]))
        XCTAssertNil(SkipEngine.active(segs, at: 19.9, settings: settings, ignored: []))
        XCTAssertEqual(SkipEngine.autoSkipStarts(segs, settings: settings, ignored: []), [10])
    }

    func testYouTubeIDs() {
        for s in ["dQw4w9WgXcQ", "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3", "https://youtu.be/dQw4w9WgXcQ",
                  "https://youtube.com/shorts/dQw4w9WgXcQ", "https://www.youtube.com/live/dQw4w9WgXcQ?si=x"] {
            XCTAssertEqual(SkipEngine.parseYouTubeID(s), "dQw4w9WgXcQ", s)
        }
        XCTAssertNil(SkipEngine.parseYouTubeID("nope"))
    }

    func testServerAndSponsorBlockDecoding() throws {
        let (segs, links) = SkipClient.decodeServer(try fixture("server.json"), videoID: "v2ea9qb")
        XCTAssertEqual(segs.map(\.uuid), ["s1", "s2"], "unknown categories dropped")
        XCTAssertEqual(segs[0].votes, 3)
        XCTAssertEqual(links.first?.youtubeID, "dQw4w9WgXcQ")
        XCTAssertEqual(links.first?.offset, 2.5)

        let sb = SkipClient.decodeSponsorBlock(try fixture("sb.json"), offset: -2)
        XCTAssertEqual(sb.map(\.uuid), ["yt:sbA", "yt:sbC"], "poi highlight dropped")
        XCTAssertEqual(sb[0].start, 98.5, accuracy: 0.001)
        XCTAssertEqual(sb[1].start, 0, "clamped at 0")
        XCTAssertEqual(sb[1].end, 2)
        XCTAssertEqual(sb[0].source, .youtube)
    }

    func testSHA256MatchesServerHashing() {
        XCTAssertEqual(SHA256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(String(repeating: "a", count: 1000)).prefix(8), "41edece4")
    }

    // MARK: Library
    func testLibrary() {
        var lib = LibraryData()
        let v = VideoItem(id: "v1", url: "u", title: "T")
        lib.recordWatch(v); lib.recordWatch(VideoItem(id: "v2", url: "u", title: "T2")); lib.recordWatch(v)
        XCTAssertEqual(lib.history.map(\.id), ["v1", "v2"])
        lib.toggleWatchLater(v); XCTAssertTrue(lib.inWatchLater("v1")); lib.toggleWatchLater(v); XCTAssertFalse(lib.inWatchLater("v1"))
        let c = ChannelRef(path: "/c/Redacted", name: "Redacted News")
        lib.toggleFollow(c); XCTAssertTrue(lib.isFollowing("/c/redacted")); lib.toggleFollow(c); XCTAssertTrue(lib.follows.isEmpty)
        lib.savePosition("v1", 120)
        XCTAssertEqual(lib.resumePosition(for: "v1", duration: 600), 120)
        XCTAssertNil(lib.resumePosition(for: "v1", duration: 125), "near the end starts over")
        lib.savePosition("v1", 3); XCTAssertNil(lib.resumePosition(for: "v1", duration: 600))

        let data = try! JSONEncoder().encode(lib)
        XCTAssertEqual(try! JSONDecoder().decode(LibraryData.self, from: data), lib)
    }

    func testListingDecoding() throws {
        let json = #"{"items":[{"id":"v7gygbk","url":"https://rumble.com/v7gygbk-x.html","title":"T","duration":"1:17","channelPath":"/user/R","channelName":"R","published":"2026-10-16T14:24:34-04:00","views":"1.81K"}],"hasNext":true,"channel":null,"empty":false}"#
        let page = try JSONDecoder().decode(ListingPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items[0].durationSeconds, 77)
        XCTAssertNotNil(page.items[0].publishedDate)
        XCTAssertEqual(page.items[0].channel?.path, "/user/R")
        XCTAssertTrue(page.hasNext)
    }

    func testPreferencesAndMigration() throws {
        // A 0.2-era library file (no prefs key) must still load with everything intact.
        let old = #"{"follows":[{"path":"/c/A","name":"A"}],"watchLater":[],"history":[],"positions":{"v1":42},"skip":{"serverURL":"","actions":{},"useYouTubeLinks":true,"showNotice":true,"userID":"abcdefghijklmnop"},"localSegments":{},"localLinks":{},"skipStats":{"skips":3,"secondsSaved":90}}"#
        let lib = try JSONDecoder().decode(LibraryData.self, from: Data(old.utf8))
        XCTAssertEqual(lib.follows.first?.path, "/c/A")
        XCTAssertEqual(lib.positions["v1"], 42)
        XCTAssertEqual(lib.skipStats.skips, 3)
        XCTAssertEqual(lib.prefs, AppPreferences())

        var p = AppPreferences()
        XCTAssertEqual(p.visibleTabs, [.home, .shorts, .search, .inbox, .library])
        p.tabs = [TabSetting(tab: .library, enabled: false), TabSetting(tab: .shorts, enabled: false),
                  TabSetting(tab: .search, enabled: true), TabSetting(tab: .home, enabled: true)]
        XCTAssertEqual(p.visibleTabs, [.library, .search, .home, .inbox], "library forced on, order kept, missing tab appended")
        XCTAssertEqual(p.action(for: .doubleTapRight), .seekForward)
        p.gestures[PlayerGesture.doubleTapRight.rawValue] = .skipSegment
        XCTAssertEqual(p.action(for: .doubleTapRight), .skipSegment)
        XCTAssertFalse(PlayerGesture.swipeUp.allowedActions.contains(.speedBoost))
        XCTAssertTrue(PlayerGesture.longPress.allowedActions.contains(.speedBoost))

        let round = try JSONDecoder().decode(AppPreferences.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(round, p)
        let partial = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"theme":"dark"}"#.utf8))
        XCTAssertEqual(partial.theme, .dark)
        XCTAssertEqual(partial.seekSeconds, 10)
    }
}
