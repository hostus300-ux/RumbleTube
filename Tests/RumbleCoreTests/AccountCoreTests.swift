import XCTest
@testable import RumbleCore

final class AccountCoreTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testCommentTree() throws {
        let page = try CommentParser.parse(try fixture("comments.json"))
        XCTAssertEqual(page.totalText, "54 Comments")
        XCTAssertEqual(page.videoNumericID, "445329064")
        XCTAssertEqual(page.comments.map(\.id), ["1001", "2001"], "create box and show-more skipped; hidden comments kept")

        let pinned = page.comments[0]
        XCTAssertTrue(pinned.pinned)
        XCTAssertTrue(pinned.isVideoOwner)

        let mine = page.comments[1]
        XCTAssertEqual(mine.author, "demo_user")
        XCTAssertEqual(mine.authorPath, "/user/demo_user")
        XCTAssertEqual(mine.upVotes, 1200)
        XCTAssertEqual(mine.downVotes, 3)
        XCTAssertTrue(mine.canDelete)
        XCTAssertEqual(mine.avatar, "https://hugh.cdn.rumble.cloud/video/z0/a/b.jpeg")
        XCTAssertEqual(mine.timeText, "5 weeks ago")
        XCTAssertEqual(mine.replies.map(\.id), ["2002", "2004"])
        XCTAssertEqual(mine.replies[0].text, "I disagree & here's why.\nSecond line")
        XCTAssertEqual(mine.replies[0].avatar, "https://x.rumble.cloud/r.jpeg")
        XCTAssertFalse(mine.replies[0].canDelete)
        XCTAssertEqual(mine.replies[1].replies.map(\.id), ["2003"], "third level nests")
        XCTAssertEqual(mine.text, "My original comment", "own text only, not replies'")
        XCTAssertEqual(page.flattened.count, 5)
    }

    func testFindNotifiedComment() throws {
        let page = try CommentParser.parse(try fixture("comments.json"))
        XCTAssertEqual(page.path(to: "2003"), ["2001", "2004", "2003"])
        XCTAssertEqual(page.thread(containing: "2002")?.id, "2001")
        XCTAssertEqual(page.comment("2002")?.author, "replyguy")
        XCTAssertNil(page.path(to: "nope"))
    }

    func testCommentError() {
        XCTAssertThrowsError(try CommentParser.parse(try fixture("comments-error.json"))) { e in
            XCTAssertEqual(e as? AccountError, .server("Video not found"))
        }
    }

    func testNotifications() throws {
        let feed = try NotificationParser.parse(try fixture("notifications.json"))
        XCTAssertTrue(feed.loggedIn)
        XCTAssertTrue(feed.hasUnread)
        XCTAssertEqual(feed.items.count, 2)
        let n = feed.items[0]
        XCTAssertEqual(n.type, "comment_reply")
        XCTAssertEqual(n.commentID, "2002")
        XCTAssertFalse(n.read)
        XCTAssertEqual(n.body, "replyguy replied to your comment on \"Big Show Episode 12\".")
        XCTAssertEqual(n.actorName, "replyguy")
        XCTAssertEqual(n.actorPath, "/user/replyguy")
        XCTAssertEqual(n.video?.id, "v7aaaaa")
        XCTAssertEqual(n.video?.url, "https://rumble.com/v7aaaaa-big-show-episode-12.html")
        XCTAssertEqual(n.video?.duration, "1:28:41")
        XCTAssertEqual(n.video?.channelPath, "/c/BigShow")
        XCTAssertEqual(n.commentListID, "7bbbbb")
        XCTAssertEqual(n.videoNumericID, "445329064")
        XCTAssertTrue(n.isCommentRelated)

        let other = feed.items[1]
        XCTAssertTrue(other.read)
        XCTAssertNil(other.commentID)
        XCTAssertNil(other.video)
        XCTAssertEqual(other.actorPath, "/c/BigShow")
        XCTAssertFalse(other.isCommentRelated)
    }

    func testRequests() throws {
        let add = AccountRequests.addComment(videoNumericID: "445329064", text: "Hi & bye = ok?", replyTo: "2002")
        XCTAssertEqual(add.httpMethod, "POST")
        XCTAssertEqual(add.url?.absoluteString, "https://rumble.com/service.php?name=comment.add")
        XCTAssertEqual(String(decoding: add.httpBody ?? Data(), as: UTF8.self),
                       "comment=Hi%20%26%20bye%20%3D%20ok%3F&reply_id=2002&video=445329064")
        XCTAssertEqual(add.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")

        let vote = AccountRequests.vote(contentID: "2002", type: 2, vote: -1)
        XCTAssertEqual(String(decoding: vote.httpBody ?? Data(), as: UTF8.self), "id=2002&type=2&vote=-1")
        XCTAssertEqual(AccountRequests.comments(listID: "7bbbbb").url?.absoluteString,
                       "https://rumble.com/service.php?video=7bbbbb&name=comment.list")
        XCTAssertEqual(AccountRequests.notifications().url?.absoluteString,
                       "https://rumble.com/service.php?api=7&limit=50&name=user.notification_feed")
        XCTAssertEqual(AccountRequests.deleteComment("9").url?.absoluteString,
                       "https://rumble.com/service.php?comment_id=9&name=comment.delete")
    }

    func testUsernameAndResults() throws {
        XCTAssertEqual(AccountRequests.username(fromPage: String(decoding: try fixture("home.html"), as: UTF8.self)), "demo_user")
        XCTAssertNil(AccountRequests.username(fromPage: #"$$.user={username:"",logged_in:false}"#))
        if case .failure(let e) = AccountRequests.parseResult(Data(#"{"data":{"error":"Too fast"}}"#.utf8)) {
            XCTAssertEqual(e, .server("Too fast"))
        } else { XCTFail() }
        if case .failure(let e) = AccountRequests.parseResult(Data(#"{"user":{"logged_in":false},"data":{}}"#.utf8)) {
            XCTAssertEqual(e, .notLoggedIn)
        } else { XCTFail() }
        if case .success(let d) = AccountRequests.parseResult(Data(#"{"data":{"comment_id":555}}"#.utf8)) {
            XCTAssertEqual(d["comment_id"] as? Int, 555)
        } else { XCTFail() }
    }
}

final class ShortsCoreTests: XCTestCase {
    func testShortsFeed() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "shorts.json", withExtension: nil, subdirectory: "Fixtures"))
        let page = try ShortsParser.parse(try Data(contentsOf: url))
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items.map(\.id), ["v7aaa01", "v7aaa03"], "items without mp4 dropped; id from relative_url")
        let s = page.items[0]
        XCTAssertEqual(s.title, "Short & sweet")
        XCTAssertEqual(s.numericID, "447767024")
        XCTAssertEqual(s.commentListID, "7el78w")
        XCTAssertEqual(s.bestStream?.height, 720)
        XCTAssertEqual(s.streams.first?.height, 1080)
        XCTAssertEqual(s.likes, 120); XCTAssertEqual(s.dislikes, 4); XCTAssertEqual(s.myVote, 1)
        XCTAssertEqual(s.comments, 14)
        XCTAssertEqual(s.channel?.path, "/c/demoshow")
        XCTAssertEqual(s.asVideoItem.duration, "1:16")
        XCTAssertEqual(ShortsParser.request(offset: 20).url?.absoluteString,
                       "https://rumble.com/service.php?name=shorts.feed&offset=20&limit=10&api=7")
    }
}

final class YouTubeMatchTests: XCTestCase {
    func page(_ name: String) throws -> [YouTubeCandidate] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return YouTubeMatcher.parseSearch(try String(contentsOf: url))
    }

    // Real YouTube results captured Oct 2026.
    func testSameEditIsExact() throws {
        let c = try page("yt-crowder.html")
        XCTAssertFalse(c.isEmpty)
        let m = YouTubeMatcher.bestMatch(
            title: "The History of the U.S. Navy: American Masterclass with Historian David Barton | Louder With Crowder",
            channel: "Steven CrowderVerified", duration: TimeFormat.parseClock("12:05"), candidates: c)
        XCTAssertEqual(m?.confidence, .exact)
        XCTAssertEqual(m?.candidate.videoID, "OsOA8gWprTQ")
    }

    func testReuploadByAnotherChannelIsRejected() throws {
        let c = try page("yt-reupload.html")
        XCTAssertGreaterThan(c.count, 3, "real Benny Johnson results to choose from")
        let m = YouTubeMatcher.bestMatch(title: "Benny Johnson 🚩 Are you sitting down? This is massive.",
                                         channel: "galacticstorm", duration: TimeFormat.parseClock("1:56"), candidates: c)
        XCTAssertNil(m, "a clip re-uploaded by someone else must not borrow the original's segments")
    }

    func testLongerLiveVersionIsDifferentEdit() throws {
        let m = YouTubeMatcher.bestMatch(title: "Ilhan Omar PHONE SEIZED, Trump Wants To DEPORT HER | Timcast IRL",
                                         channel: "TimcastIRLVerified", duration: TimeFormat.parseClock("2:42:09"),
                                         candidates: try page("yt-timcast.html"))
        XCTAssertEqual(m?.confidence, .differentEdit)
        XCTAssertFalse(m!.confidence.usable)
        let rec = AutoLinkRecord.from(m, rumbleDuration: TimeFormat.parseClock("2:42:09"))
        XCTAssertEqual(rec.lengthDifference!, 2204, accuracy: 2)
    }

    func testRules() {
        XCTAssertEqual(YouTubeMatcher.confidence(0.95, 0.9, 2, 600), .exact)
        XCTAssertEqual(YouTubeMatcher.confidence(0.7, 0.8, 10, 600), .likely)
        XCTAssertEqual(YouTubeMatcher.confidence(0.95, 0.9, 400, 6000), .differentEdit)
        XCTAssertEqual(YouTubeMatcher.confidence(0.5, 1.0, 1, 600), .none, "same channel, different video")
        XCTAssertEqual(YouTubeMatcher.confidence(0.95, 0.2, 1, 600), .exact, "identical title & length despite a renamed channel")
        XCTAssertEqual(YouTubeMatcher.confidence(0.95, 0.9, nil, 600), .none, "never match without lengths")
        XCTAssertEqual(YouTubeMatcher.cleanChannel("@MurTechVerified"), "MurTech")
        XCTAssertEqual(YouTubeMatcher.query(title: "Benny Johnson 🚩 Are you sitting down?", channel: "galacticstorm"),
                       "Benny Johnson Are you sitting down? galacticstorm")
        XCTAssertEqual(YouTubeMatcher.query(title: "X | Timcast IRL", channel: "Timcast IRL"), "X | Timcast IRL")
    }

    func testConfirmOnlySegmentsShowButton() {
        var settings = SkipSettings()
        settings.actions = [:]
        let s = SkipSegment(uuid: "yt:a", start: 10, end: 20, category: .sponsor, source: .youtube, votes: 1,
                            videoDuration: 600, needsConfirm: true)
        XCTAssertEqual(SkipEngine.active([s], at: 12, settings: settings, ignored: [])?.1, .button)
        XCTAssertTrue(SkipEngine.autoSkipStarts([s], settings: settings, ignored: []).isEmpty)
        // old saved settings without the new key keep the server URL
        let old = #"{"serverURL":"https://x.workers.dev","actions":{},"useYouTubeLinks":true,"showNotice":true,"userID":"abcdefghijklmnopq"}"#
        let decoded = try! JSONDecoder().decode(SkipSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.serverURL, "https://x.workers.dev")
        XCTAssertTrue(decoded.autoMatchYouTube)
    }
}

final class FeedParserTests: XCTestCase {
    func text(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try String(contentsOf: url)
    }
    func data(_ name: String) throws -> Data { Data(try text(name).utf8) }

    func testHomepageRows() throws {
        let home = try HomeParser.parse(try text("home-page.html"))
        XCTAssertEqual(home.hero.first?.id, "v7h3x8q")
        XCTAssertEqual(home.rows.map(\.title), ["Continue Watching", "Live", "Vlogs"], "shorts, empty and playlist rows dropped")
        XCTAssertEqual(home.pills.map(\.title), ["Live", "Vlogs"], "My Feed / Shorts / empty pills dropped")
        let live = home.rows[1].items[0]
        XCTAssertEqual(live.live, true)
        XCTAssertEqual(live.watching, 10209)
        XCTAssertEqual(live.channelName, "TimcastIRL")
        XCTAssertEqual(live.channelPath, "/c/TimcastIRL")
        XCTAssertNotNil(live.channelAvatar)
        XCTAssertEqual(live.progress, 1500)
        XCTAssertEqual(live.numericID, "448343828")
        XCTAssertEqual(live.commentListID, "7exkb8")
        XCTAssertNil(live.duration)
        XCTAssertEqual(home.rows[1].items[1].upcoming, true)
        XCTAssertEqual(home.rows[1].items[1].live, false)
        XCTAssertEqual(home.rows[2].items.map(\.id), ["v7h08m8"], "short removed from a video row")
        XCTAssertEqual(home.rows[2].items[0].duration, "8:40")
        XCTAssertEqual(home.rows[0].feedPath, "/playlists/watch-history")
    }

    func testServerRenderedCards() throws {
        let page = try ListingParser.parse(try text("editor-picks.html"), url: URL(string: "https://rumble.com/editor-picks")!)
        XCTAssertEqual(page.items.map(\.id), ["v7h3x8q", "v7gf2pg"], "sidebar and Play All button ignored")
        let a = page.items[0], b = page.items[1]
        XCTAssertEqual(a.title, "Riots EXPLODE Across Europe, France Is On FIRE | Timcast IRL")
        XCTAssertEqual(a.live, true)
        XCTAssertEqual(a.watching, 10200)
        XCTAssertEqual(a.views, "29K")
        XCTAssertEqual(a.channelName, "TimcastIRL")
        XCTAssertEqual(a.channelAvatar, "https://hugh.cdn.rumble.cloud/video/z8/J/Y/p/d/JYpda.baa.2-TimcastIRL-srjiah.jpeg")
        XCTAssertTrue(a.thumbnail!.hasPrefix("https://hugh.cdn.rumble.cloud/"))
        XCTAssertEqual(b.duration, "2:26:54")
        XCTAssertEqual(b.live, false)
        XCTAssertEqual(b.channelPath, "/c/welikeshooting")
        XCTAssertEqual(b.publishedText, "6 days ago")
        XCTAssertTrue(page.hasNext)
        XCTAssertNil(page.channel)
    }

    func testChannelJSONGrid() throws {
        let page = try ListingParser.parse(try text("channel-grid.html"), url: URL(string: "https://rumble.com/c/welikeshooting")!)
        XCTAssertEqual(page.items.map(\.id), ["v7h08m8"], "JSON grid read; shorts excluded")
        XCTAssertEqual(page.items[0].thumbnail, "https://x/t.jpg")
        XCTAssertEqual(page.channel?.name, "We Like Shooting")
        XCTAssertEqual(page.channel?.avatar, "https://hugh.cdn.rumble.cloud/a.png")
        XCTAssertEqual(page.channel?.followers, "3.55K")
        XCTAssertEqual(page.channel?.rumbleID, "307905")
        XCTAssertEqual(page.channel?.rumbleType, "channel")
        XCTAssertEqual(page.channel?.followingOnRumble, false)
        XCTAssertTrue(page.hasNext)
        let req = FollowAPI.toggleRequest(id: "307905", type: "channel", follow: true)
        XCTAssertEqual(String(decoding: req.httpBody!, as: UTF8.self),
                       "action=toggle-following-status&collection_id=307905&size=default&state=1&type=channel")
    }

    func testMyFeed() throws {
        let chans = try FollowingAPI.parseLatest(try data("following-latest.json"))
        XCTAssertEqual(chans.map(\.ref.path), ["/c/DemoLive", "/user/quiet"])
        XCTAssertTrue(chans[0].isLive)
        XCTAssertFalse(chans[1].isLive)
        XCTAssertEqual(chans[0].ref.avatar, "https://x/l.jpg")
        let feed = try FollowingAPI.parseFeed(try data("following-feed.json"))
        XCTAssertTrue(feed.hasMore)
        XCTAssertEqual(feed.items.filter { $0.isShort != true }.map(\.id), ["v7h3x8q", "v7h08m8"])
        XCTAssertEqual(feed.items.filter { $0.isShort == true }.map(\.id), ["v7h3wvy"])
        XCTAssertEqual(feed.raw.compactMap(ShortsParser.item).map(\.id), ["v7h3wvy"], "shorts become ShortItems for the shorts pager")
        let req = FollowingAPI.feedRequest(pill: "shorts", offset: 24, timeZone: "America/Chicago")
        XCTAssertTrue(req.url!.absoluteString.contains("pill=shorts"))
        XCTAssertTrue(req.url!.absoluteString.contains("options=video.full,video.vertical_thumb"))
        XCTAssertTrue(req.url!.absoluteString.contains("offset=24"))
    }

    func testAccountPages() throws {
        let lines = try AccountPages.earnings(try text("earnings.html"))
        XCTAssertEqual(lines.map(\.label), ["YouTube Earnings", "Rumble Earnings", "Total", "Potential Recurring Revenue"])
        XCTAssertEqual(lines[1].amount, "$7.25")
        XCTAssertEqual(AccountPages.followers("<h1>exampleuser</h1><span>2 Followers</span>"), "2")
        XCTAssertEqual(AccountPages.followers("<div><span>697K</span> <span>Followers</span></div>"), "697K")
        XCTAssertEqual(AccountPages.avatar(#"<img src="https://hugh.cdn.rumble.cloud/video/z0/a.jpeg" class="x">"#),
                       "https://hugh.cdn.rumble.cloud/video/z0/a.jpeg")
    }
}

final class ChannelSearchTests: XCTestCase {
    func testChannelSearch() throws {
        let url = Bundle.module.url(forResource: "channel-search", withExtension: "html", subdirectory: "Fixtures")!
        let r = try ChannelSearchParser.parse(String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(r.map(\.ref.path), ["/c/c-6643482", "/c/TheQuartering"])
        XCTAssertEqual(r[1].ref.name, "The Quartering")
        XCTAssertEqual(r[1].followers, "350,618")
        XCTAssertTrue(r[1].verified)
        XCTAssertEqual(r[1].ref.avatar, "https://hugh.cdn.rumble.cloud/video/z8/v/Q/m/b/vQmba.baa-TheQuartering-qtissd.jpeg")
        XCTAssertNil(r[0].ref.avatar)
    }

    func testFollowingLatestLimitIsAccepted() {
        // Rumble rejects limit > 50 with "Invalid limit".
        XCTAssertTrue(FollowingAPI.latestRequest().url!.absoluteString.contains("limit=50"))
    }
}

final class LiveChatTests: XCTestCase {
    func testConfigFromWatchPage() {
        let html = "x RumbleChat(\n\t\"https://web7.rumble.com/chat/api\",\n\t\"https://rants.example/chat/api\",\n\t448347576,\n\t10000001,\n\t[[1,120],[2,180],[5,300]],\n\t0)"
        let c = LiveChatParser.config(fromWatchPage: html)
        XCTAssertEqual(c?.apiBase, "https://web7.rumble.com/chat/api")
        XCTAssertEqual(c?.chatID, "448347576")
        XCTAssertEqual(c?.rantsBase, "https://rants.example/chat/api")
        XCTAssertEqual(c?.rantLevels.map(\.dollars), [1, 2, 5])
        XCTAssertEqual(c?.rantLevels[2].durationText, "5 minutes")
        let r = LiveChatParser.rantRequest(c!, text: "hey", cents: 500, requestID: "q")
        XCTAssertEqual(r.url?.absoluteString, "https://rants.example/chat/api/chat/448347576/message")
        let body = try! JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        let rant = (body["data"] as! [String: Any])["rant"] as! [String: Any]
        XCTAssertEqual(rant["price_cents"] as? Int, 500)
        XCTAssertEqual(rant["payment_type"] as? String, "rumble-wallet")
        XCTAssertEqual(LiveChatParser.streamURL(c!).absoluteString, "https://web7.rumble.com/chat/api/chat/448347576/stream")
        XCTAssertNil(LiveChatParser.config(fromWatchPage: "<html></html>"))
    }

    func testInitEvent() throws {
        let url = Bundle.module.url(forResource: "chat-init", withExtension: "json", subdirectory: "Fixtures")!
        let e = try XCTUnwrap(LiveChatParser.parseEvent(Data(contentsOf: url)))
        XCTAssertEqual(e.type, "init")
        XCTAssertEqual(e.messages.map(\.username), ["ExampleViewer", "BigTipper", "ExampleChannel"])
        XCTAssertEqual(e.messages[0].text, "First! & hello")
        XCTAssertEqual(e.messages[1].rantCents, 5000)
        XCTAssertEqual(e.messages[1].badges, ["verified", "whale-yellow"])
        XCTAssertTrue(e.messages[2].isChannel)
    }

    func testSendBody() throws {
        let r = LiveChatParser.sendRequest(ChatConfig(apiBase: "https://web7.rumble.com/chat/api", chatID: "1"), text: "hi", requestID: "abc")
        XCTAssertEqual(r.url?.absoluteString, "https://web7.rumble.com/chat/api/chat/1/message")
        let o = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        let d = o["data"] as! [String: Any]
        XCTAssertEqual((d["message"] as! [String: Any])["text"] as? String, "hi")
        XCTAssertEqual(d["request_id"] as? String, "abc")
    }
}

final class DiscoveryTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!

    func v(_ id: String, ch: String, hoursAgo: Double, views: Int, likes: Int = 0, comments: Int = 0,
           title: String = "A video", live: Bool = false, watching: Int? = nil, category: String? = nil) -> VideoItem {
        var x = VideoItem(id: id, url: "https://rumble.com/\(id)", title: title, thumbnail: nil, duration: "10:00",
                          channelName: ch, channelPath: "/c/\(ch)", channelAvatar: nil, views: nil,
                          published: ISO8601DateFormatter().string(from: now.addingTimeInterval(-hoursAgo * 3600)),
                          publishedText: nil, live: live, upcoming: false)
        x.viewCount = views; x.likes = likes; x.commentCount = comments; x.watching = watching; x.category = category
        return x
    }

    func testTrendingPrefersFreshVelocityAndDropsOld() {
        let items = [
            v("old", ch: "A", hoursAgo: 24 * 6, views: 500_000, likes: 5000),   // big but 6 days old
            v("hot", ch: "B", hoursAgo: 5, views: 60_000, likes: 3000, comments: 400),
            v("meh", ch: "C", hoursAgo: 30, views: 2_000),
            v("ancient", ch: "D", hoursAgo: 24 * 10, views: 9_000_000),           // outside 7 days
        ]
        let r = TrendingRanker.videos(items, now: now, minimum: 0)
        XCTAssertEqual(r.first?.id, "hot")
        XCTAssertFalse(r.contains { $0.id == "ancient" })
        XCTAssertEqual(r.first?.reason, "↑ 12K views/hr")
    }

    func testMeasuredVelocityUsesSnapshot() {
        let a = v("a", ch: "A", hoursAgo: 48, views: 100_000)
        let prev = ["a": ViewSnapshot(views: 90_000, at: now.addingTimeInterval(-2 * 3600))]
        let vel = TrendingRanker.velocity(a, now: now, previous: prev["a"])!
        XCTAssertEqual(vel.perHour, 5000, accuracy: 0.1)
        XCTAssertTrue(vel.measured)
    }

    func testDiversityAndFallback() {
        let same = (0..<5).map { v("s\($0)", ch: "Same", hoursAgo: 2 + Double($0), views: 50_000 - $0 * 100) }
        let other = v("o", ch: "Other", hoursAgo: 3, views: 1_000)
        let r = TrendingRanker.videos(same + [other], now: now, minimum: 0)
        XCTAssertEqual(Array(r.prefix(3)).filter { $0.item.channelName == "Same" }.count, 2, "max 2 per channel early on")
        XCTAssertEqual(r.count, 6, "held items still appear later")
        var noViews = v("n", ch: "N", hoursAgo: 1, views: 0); noViews.viewCount = nil
        XCTAssertEqual(TrendingRanker.videos([noViews], now: now).map(\.id), ["n"], "unscored fill newest-first")
    }

    func testLiveRanksByViewersAndChat() {
        let a = v("a", ch: "A", hoursAgo: 1, views: 0, live: true, watching: 40_000)
        let b = v("b", ch: "B", hoursAgo: 1, views: 0, live: true, watching: 800)
        XCTAssertEqual(TrendingRanker.live([b, a]).map(\.id), ["a", "b"])
        let r = TrendingRanker.live([b, a], chatPerMinute: ["b": 3000])
        XCTAssertEqual(r.first?.id, "b", "very active chat lifts a smaller stream")
        XCTAssertEqual(r.first?.reason, "3000 chats/min")
    }

    func testForYouProfileAndRanking() {
        let hist = (0..<6).map { i in
            (video: v("h\(i)", ch: "Timcast", hoursAgo: Double(i) * 24, views: 1, title: "Election fraud debate night \(i)",
                      category: "News"), at: now.addingTimeInterval(-Double(i) * 86_400))
        }
        let p = TasteProfile.build(history: hist, completion: { _ in 1 }, follows: [], now: now)
        XCTAssertFalse(p.isCold)
        XCTAssertEqual(p.topChannels.first, "/c/timcast")
        XCTAssertTrue(p.keywords.keys.contains("election"))
        let cands = [
            v("c1", ch: "Cooking", hoursAgo: 2, views: 10, title: "Pasta recipe", category: "Food"),
            v("c2", ch: "Other", hoursAgo: 2, views: 10, title: "Election night debate recap", category: "News"),
            v("c3", ch: "Timcast", hoursAgo: 2, views: 10, title: "Tonight", category: "News"),
            v("h0", ch: "Timcast", hoursAgo: 2, views: 10, title: "Already seen"),
        ]
        let r = ForYouRanker.rank(cands, profile: p, live: false, watchedFraction: { $0.id == "h0" ? 1 : nil })
        XCTAssertEqual(r.first?.id, "c3")
        XCTAssertEqual(r.first?.reason, "Because you watch Timcast")
        XCTAssertTrue(r.contains { $0.id == "c2" })
        XCTAssertFalse(r.contains { $0.id == "c1" }, "unrelated content dropped")
        XCTAssertFalse(r.contains { $0.id == "h0" }, "finished videos hidden")
    }

    func testHomePageIsCodable() throws {
        let page = HomePage(hero: [v("a", ch: "A", hoursAgo: 1, views: 1)], rows: [HomeRow(id: "r", title: "Row", feedPath: "/x", items: [])],
                            pills: [HomePill(id: "r", title: "Row")])
        let back = try JSONDecoder().decode(HomePage.self, from: JSONEncoder().encode(page))
        XCTAssertEqual(back.rows.first?.title, "Row")
        XCTAssertEqual(back.hero.first?.viewCount, 1)
    }
}

final class ChatEmoteTests: XCTestCase {
    func testParseAndSegment() {
        let json = #"{"data":{"items":[{"id":1,"title":"Rumble Emotes","emotes":[{"name":"r+rumblecharge","is_subs_only":false,"file":"https://e.example/charge.gif"}]},{"id":2,"title":"ExampleChannel","emotes":[{"name":"examplech+hype","is_subs_only":true,"file":"https://e.example/hype.png"}]}]}}"#
        let e = ChatEmotes.parse(Data(json.utf8))
        XCTAssertEqual(e.count, 2)
        XCTAssertTrue(e["examplech+hype"]!.subsOnly)
        let s = ChatEmotes.segments("Let's go :r+rumblecharge::ExampleCh+Hype: and :unknown: ok", emotes: e)
        XCTAssertEqual(s, [.text("Let's go "), .emote(e["r+rumblecharge"]!), .emote(e["examplech+hype"]!), .text(" and :unknown: ok")])
        XCTAssertEqual(ChatEmotes.segments("no emotes", emotes: e), [.text("no emotes")])
        XCTAssertEqual(ChatEmotes.parse(Data(#"{"items":[{"emotes":[{"name":"a","file":"x"}]}]}"#.utf8)).count, 1)
    }
}

final class DiagLogTests: XCTestCase {
    func testLogsPathsNotQueries() {
        let d = DiagLog.shared
        d.clear()
        d.request(URL(string: "https://rumble.com/search/video?q=secret+words"), status: 403)
        d.log("player", "Playback failed")
        let r = d.report(header: ["App": "0.9.0"])
        XCTAssertTrue(r.contains("rumble.com/search/video → HTTP 403"))
        XCTAssertFalse(r.contains("secret"))
        XCTAssertTrue(r.contains("[player] Playback failed"))
        XCTAssertTrue(r.contains("App: 0.9.0"))
        d.clear()
        XCTAssertTrue(d.report(header: [:]).contains("no problems logged"))
    }
}

final class DownloadPlanTests: XCTestCase {
    func testPicksBestMP4UnderLimit() {
        let s = [StreamOption(kind: .hls, height: nil, bitrate: nil, url: "h"),
                 StreamOption(kind: .mp4, height: 1080, bitrate: nil, url: "1080"),
                 StreamOption(kind: .mp4, height: 720, bitrate: nil, url: "720"),
                 StreamOption(kind: .mp4, height: 360, bitrate: nil, url: "360")]
        XCTAssertEqual(DownloadPlan.stream(from: s, maxHeight: 720)?.url, "720")
        XCTAssertEqual(DownloadPlan.stream(from: s, maxHeight: 240)?.url, "360", "falls back to the smallest")
        XCTAssertNil(DownloadPlan.stream(from: [s[0]], maxHeight: 720), "HLS-only (live) can't be downloaded")
    }
}

final class LiveAlertTests: XCTestCase {
    func testOnlyNewlyLive() {
        let a = FollowedChannel(ref: ChannelRef(path: "/c/A", name: "A"), lastActivity: nil, liveViewers: 100, followers: nil)
        let b = FollowedChannel(ref: ChannelRef(path: "/c/B", name: "B"), lastActivity: nil, liveViewers: 5, followers: nil)
        let c = FollowedChannel(ref: ChannelRef(path: "/c/C", name: "C"), lastActivity: nil, liveViewers: 0, followers: nil)
        let prev: Set<String> = ["/c/a"]
        XCTAssertEqual(LiveAlertTracker.newlyLive(previous: prev, current: [a, b, c]).map(\.ref.name), ["B"])
        XCTAssertEqual(LiveAlertTracker.liveIDs([a, b, c]), ["/c/a", "/c/b"])
    }
}

final class TimestampTests: XCTestCase {
    func testFindAndChapters() {
        let t = "Skip to 1:23 or 01:02:03, not 12:345 or 2024:10 or 1:75"
        XCTAssertEqual(Timestamps.find(in: t).map(\.seconds), [83, 3723])
        let desc = """
        Today's show!
        0:00 Intro
        2:15 - The news
        (10:30) Interview
        Final thoughts 45:00
        Support us at example.com
        """
        let ch = Timestamps.chapters(in: desc)
        XCTAssertEqual(ch.map(\.title), ["Intro", "The news", "Interview", "Final thoughts"])
        XCTAssertEqual(ch.map(\.start), [0, 135, 630, 2700])
        XCTAssertEqual(Timestamps.current(ch, at: 700)?.title, "Interview")
        XCTAssertTrue(Timestamps.chapters(in: "Watch at 1:00 and 2:00").isEmpty, "needs 3+ chapter lines")
    }
}

final class SearchSuggestTests: XCTestCase {
    func testHistoryAndChannels() {
        var lib = LibraryData()
        lib.addSearch("timcast"); lib.addSearch("crowder"); lib.addSearch("Timcast")
        XCTAssertEqual(lib.searchHistory, ["Timcast", "crowder"], "dedupes case-insensitively, newest first")
        let chans = [ChannelRef(path: "/c/TimcastIRL", name: "TimcastIRL"), ChannelRef(path: "/c/Other", name: "Other")]
        let s = SearchSuggest.items(for: "tim", history: lib.searchHistory, channels: chans)
        XCTAssertEqual(s, [.recent("Timcast"), .channel(chans[0])])
        XCTAssertEqual(SearchSuggest.items(for: "", history: lib.searchHistory, channels: chans), [.recent("Timcast"), .recent("crowder")])
    }
}

final class HistoryMergeTests: XCTestCase {
    func item(_ id: String, progress: Double? = nil) -> VideoItem {
        var v = VideoItem(id: id, url: "https://rumble.com/\(id)", title: id, thumbnail: nil, duration: "10:00", channelName: nil,
                          channelPath: nil, channelAvatar: nil, views: nil, published: nil, publishedText: nil, live: false, upcoming: false)
        v.progress = progress
        return v
    }

    func testMergeKeepsOrderAndProgress() {
        var lib = LibraryData()
        let now = Date()
        lib.history = [HistoryEntry(video: item("local1"), watchedAt: now.addingTimeInterval(-60)),
                       HistoryEntry(video: item("b"), watchedAt: now.addingTimeInterval(-3600))]
        lib.positions["b"] = 30
        lib.mergeRemoteHistory([item("a", progress: 100), item("b", progress: 20), item("c", progress: 600)], now: now)
        XCTAssertEqual(lib.history.map(\.id), ["a", "local1", "b", "c"])
        XCTAssertEqual(lib.positions["a"], 100)
        XCTAssertEqual(lib.positions["b"], 30, "keeps the further position")
        XCTAssertEqual(lib.watchFraction(for: item("c")), 1, "finished videos count as watched")
    }

    func testWatchedPercentageOnCards() throws {
        let html = """
        <div class="videostream videostream__list-item" data-video-id="1"><div class="thumbnail__thumb">
        <img class="thumbnail__image" src="https://x/t.jpg"><div class="videostream__info"><div class="videostream__badge videostream__status videostream__status--duration"> 10:00 </div></div>
        <div class="videostream__watched" style="--watched-percentage: 60.1%"></div>
        <a class="videostream__link link" href="/v7abc12-some-video.html?playlist_id=watch-history"></a></div>
        <div class="videostream__footer"><a class="title__link link" href="/v7abc12-some-video.html"><h3 class="thumbnail__title" title="Some video">Some video</h3></a></div></div>
        """
        let page = try ListingParser.parse(html, url: URL(string: "https://rumble.com/playlists/watch-history")!)
        XCTAssertEqual(page.items.first?.id, "v7abc12")
        XCTAssertEqual(page.items.first?.progress ?? 0, 360.6, accuracy: 0.5)
    }
}

final class UpcomingTests: XCTestCase {
    func make(_ extra: [String: Any]) -> VideoItem? {
        var v: [String: Any] = ["title": "Stream", "relative_url": "/v7abcde-stream.html", "upload_date": "2026-10-22T13:14:34+00:00"]
        extra.forEach { v[$0.key] = $0.value }
        return RumbleJSON.video(v)
    }

    func testEndedStreamIsNotUpcoming() {
        // what Rumble sends after a stream ends
        let ended = make(["live": false, "live_placeholder": true, "livestream_status": 0, "duration": 8002])
        XCTAssertEqual(ended?.upcoming, false)
        XCTAssertEqual(ended?.isLive, false)
        XCTAssertNotNil(ended?.duration)
        let scheduled = make(["live": false, "live_placeholder": true, "livestream_status": 1, "duration": 0])
        XCTAssertEqual(scheduled?.upcoming, true)
        let liveNow = make(["live": true, "livestream_status": 2, "watching_now": 1234])
        XCTAssertEqual(liveNow?.isLive, true)
        XCTAssertEqual(liveNow?.upcoming, false)
        XCTAssertEqual(liveNow?.watching, 1234)
    }
}

final class LiveViewersTests: XCTestCase {
    func testParse() {
        let json = #"{"data":{"video_id":448541400,"num_watching_now":5795,"viewer_count":5795,"livestream_status":2}}"#
        let r = LiveViewers.parse(Data(json.utf8))
        XCTAssertEqual(r?.viewers, 5795)
        XCTAssertEqual(r?.status, 2)
        XCTAssertEqual(LiveViewers.request(videoID: "1").url?.absoluteString,
                       "https://wn0.rumble.com/service.php?video_id=1&name=video.watching-now")
    }
}

final class MutingTests: XCTestCase {
    func testMuteMatchAndTags() {
        var lib = LibraryData()
        lib.mute(path: "/c/SpamChannel?e9s=x", name: "Spam Channel", tag: "  Content spam that goes on and on  ")
        let e = lib.muteEntry(path: "/c/spamchannel", name: nil)
        XCTAssertEqual(e?.tag, "Content spam that go", "tags are cut to 20 characters")
        XCTAssertEqual(e?.tag?.count, MuteTag.maxLength)
        lib.mute(path: nil, name: "TrollUser", tag: "")
        XCTAssertNotNil(lib.muteEntry(path: "/user/trolluser", name: nil), "commenters match by their /user/ path")
        XCTAssertNotNil(lib.muteEntry(path: nil, name: "trolluser"), "or by username")
        XCTAssertNil(lib.muteEntry(path: nil, name: "trolluser")?.tag)
        XCTAssertNil(lib.muteEntry(path: "/c/other", name: "Other"))
        lib.unmute("/user/trolluser")
        XCTAssertNil(lib.muteEntry(path: nil, name: "TrollUser"))
        let back = try! JSONDecoder().decode(LibraryData.self, from: JSONEncoder().encode(lib))
        XCTAssertEqual(back.muted.count, 1)
    }
}

final class HomeIconTests: XCTestCase {
    func testProfile() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let d = try HomeIconProfile.make(name: "  My Rumble ", iconPNG: png, bundleID: "com.example.app")
        let p = try PropertyListSerialization.propertyList(from: d, format: nil) as! [String: Any]
        XCTAssertEqual(p["PayloadType"] as? String, "Configuration")
        let clip = (p["PayloadContent"] as! [[String: Any]])[0]
        XCTAssertEqual(clip["Label"] as? String, "My Rumble")
        XCTAssertEqual(clip["URL"] as? String, "rumbletube://open")
        XCTAssertEqual(clip["Icon"] as? Data, png)
        XCTAssertEqual(clip["TargetApplicationBundleIdentifier"] as? String, "com.example.app")
    }
}

final class SettingsBackupTests: XCTestCase {
    func testRoundTripAndMerge() throws {
        var old = LibraryData()
        old.prefs.autoplay = false
        old.prefs.discoverSort = "Newest"
        old.mute(path: "/c/SpamTown", name: "SpamTown", tag: "Spam")
        old.follows = [ChannelRef(path: "/c/Example", name: "Example")]
        old.history = [HistoryEntry(video: VideoItem(id: "v1", url: "https://rumble.com/v1-x.html", title: "x"), watchedAt: Date())]
        let file = try SettingsBackup(from: old, appVersion: "0.12.0").encoded()
        XCTAssertFalse(String(decoding: file, as: UTF8.self).contains("v1-x"), "watch history is never exported")

        var fresh = LibraryData()
        fresh.mute(path: "/c/SpamTown", name: "SpamTown", tag: nil)
        fresh.mute(path: "/user/other", name: "other", tag: nil)
        let b = try SettingsBackup.decode(file)
        b.apply(to: &fresh)
        XCTAssertFalse(fresh.prefs.autoplay)
        XCTAssertEqual(fresh.prefs.discoverSort, "Newest")
        XCTAssertEqual(fresh.muted.count, 2)
        XCTAssertEqual(fresh.muteEntry(path: "/c/spamtown", name: nil)?.tag, "Spam")
        XCTAssertEqual(fresh.follows.count, 1)
        b.apply(to: &fresh)
        XCTAssertEqual(fresh.follows.count, 1, "importing twice doesn't duplicate")
        XCTAssertTrue(b.summary.contains("1 muted"))
    }
}

final class DiscoverSectionsTests: XCTestCase {
    func testBrowse() throws {
        let html = """
        <ul><li class="category"><a class="category__link link" href="/category/gaming"><img class="category__image" src="https://example.com/g.jpg"><strong class="category__title truncate">Gaming</strong></a><small class="category__views">1.2K viewers</small></li>
        <li class="category"><a class="category__link link" href="/category/news"><img class="category__image" src=""><strong class="category__title">News</strong></a></li></ul>
        """
        let c = try BrowseParser.parse(html)
        XCTAssertEqual(c.map(\.path), ["/category/gaming", "/category/news"])
        XCTAssertEqual(c[0].viewers, "1.2K viewers")
        XCTAssertNil(c[1].image)
    }

    func testFeaturedChannels() throws {
        let html = """
        <style>i.user-image--img--id-abc123 { background-image: url(https://example.com/a.jpg); }</style>
        <a class="main-menu-item-channel" title="Followed One" href="/c/FollowedOne">x</a>
        <h3 class="main-menu-heading"><span>Featured Channels</span></h3>
        <div><a class="main-menu-item-channel main-menu-item-channel-is-live" title="LiveShow" href="/v123-show.html?e9s=x"><div><i class='user-image user-image--img user-image--img--id-abc123'></i><span class="main-menu-item-label main-menu-item-channel-label">LiveShow 4.1K</span></div></a></div>
        <div><a class="main-menu-item-channel " title="Example Channel" href="/c/ExampleChannel?e9s=src_v1_clr"><span class="main-menu-item-label main-menu-item-channel-label">Example Channel</span></a></div>
        """
        let f = try FeaturedChannelsParser.parse(html)
        XCTAssertEqual(f.count, 2, "channels before the Featured heading are ignored")
        XCTAssertEqual(f[0].livePath, "/v123-show.html")
        XCTAssertEqual(f[0].viewers, "4.1K")
        XCTAssertEqual(f[0].avatar, "https://example.com/a.jpg")
        XCTAssertEqual(f[1].path, "/c/ExampleChannel")
        XCTAssertNil(f[1].livePath)
    }
}

final class CreatorExtrasTests: XCTestCase {
    func testTipJoinVerifiedAndCardAvatars() throws {
        let html = """
        <svg class="verification-badge-icon media-heading-verified"></svg>
        <button class="btn-red" data-js="locals-subscription-button">Join</button>
        <button hx-get="/-htmx/wallet/payment/qr-modal" hx-vals='{"eid":"Ab1-x_9","dt":"c"}'>Tip</button>
        """
        XCTAssertEqual(CreatorExtras.tipID(html), "Ab1-x_9")
        XCTAssertTrue(CreatorExtras.joinable(html))
        XCTAssertNil(CreatorExtras.tipID("<button>Tip</button>"))
        let png = Data([1, 2, 3, 4]).base64EncodedString()
        XCTAssertEqual(CreatorExtras.qrImageData(#"<img src="data:image/png;base64,\#(png)" alt="QR Code">"#), Data([1, 2, 3, 4]))
        let css = #".video-item--by-a--c42::before { background-image: url("https://example.com/a.jpg"); }"#
        XCTAssertEqual(CardAvatarCSS.map(css)["c42"], "https://example.com/a.jpg")
    }
}

final class ChannelTagTests: XCTestCase {
    func testTagging() throws {
        var lib = LibraryData()
        let pol = lib.createTag(name: "  Politics and current events ", color: ChannelTag.palette[0])!
        XCTAssertEqual(pol.name.count, ChannelTag.maxLength)
        XCTAssertEqual(lib.createTag(name: "politics and cur", color: 0)?.id, pol.id, "same name reuses the tag")
        let a = ChannelRef(path: "/c/Alpha?e9s=x", name: "Alpha")
        lib.setTag(pol, on: a, true)
        XCTAssertEqual(lib.tags(for: "/c/alpha").map(\.id), [pol.id])
        XCTAssertEqual(lib.channels(tagged: pol.id).map(\.name), ["Alpha"])
        let back = try JSONDecoder().decode(LibraryData.self, from: JSONEncoder().encode(lib))
        XCTAssertEqual(back.tags(for: "/c/Alpha").first?.name, pol.name)
        lib.deleteTag(pol.id)
        XCTAssertTrue(lib.tags(for: "/c/alpha").isEmpty)
        XCTAssertTrue(lib.taggedChannels.isEmpty)
    }
}
