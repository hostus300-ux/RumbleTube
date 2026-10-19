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
