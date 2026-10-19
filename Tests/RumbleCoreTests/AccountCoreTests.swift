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
