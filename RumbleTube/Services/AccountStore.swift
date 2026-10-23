import BackgroundTasks
import Foundation
import UIKit
import UserNotifications
import WebKit

/// Rumble sign-in state, notifications and comment actions.
/// Sign-in happens on Rumble's own page in a web view; we only keep the session cookie it sets.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    static let refreshTaskID = "com.hostus300.rumbletube.refresh"

    @Published private(set) var loggedIn = false
    @Published private(set) var username: String?
    @Published private(set) var hasUnread = false
    @Published private(set) var avatarURL: String?
    @Published private(set) var followersText: String?
    @Published private(set) var followingCount: Int?
    @Published private(set) var notifications: [RumbleNotification] = []
    @Published private(set) var loadingNotifications = false
    @Published var notificationsError: String?
    @Published var alertsEnabled: Bool = UserDefaults.standard.bool(forKey: "replyAlerts") {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: "replyAlerts") }
    }

    private var pollTask: Task<Void, Never>?
    private var session: URLSession { RumbleHTTP.session }

    private init() {}

    // MARK: - Session

    /// Copy rumble.com cookies from the web view store (where sign-in happened) to URLSession's store.
    func syncCookies() async {
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
        for c in cookies where c.domain.hasSuffix("rumble.com") { HTTPCookieStorage.shared.setCookie(c) }
    }

    func refreshStatus() async {
        await syncCookies()
        guard let res = try? await send(AccountRequests.status()), res.1 == 200,
              let obj = (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any] else { return }
        let user = obj["user"] as? [String: Any]
        // Only publish real changes: every publish redraws the whole app.
        let li = user?["logged_in"] as? Bool ?? false
        if loggedIn != li { loggedIn = li }
        let unread = ((obj["data"] as? [String: Any])?["has_unread_notifications"] as? Bool) ?? false
        if hasUnread != unread { hasUnread = unread }
        if loggedIn, username == nil, let r = try? await session.data(from: URL(string: "https://rumble.com/")!) {
            username = AccountRequests.username(fromPage: String(decoding: r.0, as: UTF8.self))
        }
        if !loggedIn, username != nil || !notifications.isEmpty { username = nil; notifications = [] }
        UIApplication.shared.applicationIconBadgeNumber = hasUnread ? 1 : 0
    }

    func signOut() async {
        for c in HTTPCookieStorage.shared.cookies ?? [] where c.domain.hasSuffix("rumble.com") {
            HTTPCookieStorage.shared.deleteCookie(c)
        }
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               for: records.filter { $0.displayName.contains("rumble") })
        loggedIn = false; username = nil; notifications = []; hasUnread = false
        avatarURL = nil; followersText = nil; followingCount = nil
        FollowedChannelCache.clear()
        MyFeedModel.shared.channels = []
        UIApplication.shared.applicationIconBadgeNumber = 0
    }

    /// Re-check unread every few minutes while the app is open.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                await self?.checkLive()
                try? await Task.sleep(nanoseconds: 180_000_000_000)
            }
        }
    }

    // MARK: - Profile (Account tab)

    func loadProfile() async {
        guard loggedIn else { return }
        if username == nil, let r = try? await session.data(from: URL(string: "https://rumble.com/")!) {
            username = AccountRequests.username(fromPage: String(decoding: r.0, as: UTF8.self))
        }
        var hx = URLRequest(url: URL(string: "https://rumble.com/-register/htmx/header-user-actions")!)
        hx.setValue("true", forHTTPHeaderField: "HX-Request")
        if let r = try? await send(hx), r.1 == 200 { avatarURL = AccountPages.avatar(String(decoding: r.0, as: UTF8.self)) ?? avatarURL }
        if let u = username, let url = URL(string: "https://rumble.com/user/\(u)"), let r = try? await session.data(from: url) {
            followersText = AccountPages.followers(String(decoding: r.0, as: UTF8.self)) ?? followersText
        }
        if let list = try? await RumbleService.shared.followedChannels() { followingCount = list.count }
    }

    func earnings() async throws -> [EarningsLine] {
        guard loggedIn else { throw AccountError.notLoggedIn }
        let (data, code) = try await send(URLRequest(url: URL(string: "https://rumble.com/account/earnings")!))
        guard code == 200 else { throw AccountError.http(code) }
        let lines = try AccountPages.earnings(String(decoding: data, as: UTF8.self))
        if lines.isEmpty { throw AccountError.badResponse }
        return lines
    }

    func setFollow(id: String, type: String, follow: Bool) async throws {
        guard loggedIn else { throw AccountError.notLoggedIn }
        let (_, code) = try await send(FollowAPI.toggleRequest(id: id, type: type, follow: follow))
        guard (200..<300).contains(code) else { throw AccountError.http(code) }
        if let n = followingCount { followingCount = max(0, n + (follow ? 1 : -1)) }
    }

    // MARK: - Notifications

    func loadNotifications() async {
        guard loggedIn else { return }
        loadingNotifications = true
        defer { loadingNotifications = false }
        do {
            let (data, code) = try await send(AccountRequests.notifications())
            guard code == 200 else { throw AccountError.http(code) }
            let feed = try NotificationParser.parse(data)
            if !feed.loggedIn { loggedIn = false; return }
            notifications = feed.items
            hasUnread = false
            notificationsError = nil
            UIApplication.shared.applicationIconBadgeNumber = 0
        } catch {
            notificationsError = error.localizedDescription
        }
    }

    /// True unless every unread notification is from someone you muted (those never alert you).
    private func hasUnreadFromUnmuted() async -> Bool {
        let lib = LibraryStore.shared.data
        guard !lib.muted.isEmpty else { return true }
        guard let res = try? await send(AccountRequests.notifications()), res.1 == 200,
              let feed = try? NotificationParser.parse(res.0) else { return true }
        let unread = feed.items.filter { !$0.read }
        guard !unread.isEmpty else { return true }
        return unread.contains { lib.muteEntry(path: $0.actorPath, name: $0.actorName) == nil }
    }

    // MARK: - Comments

    func comments(listID: String, sort: String? = nil) async throws -> CommentPage {
        let (data, code) = try await send(AccountRequests.comments(listID: listID, sort: sort))
        guard code == 200 else { throw AccountError.http(code) }
        return try CommentParser.parse(data)
    }

    /// Returns the new comment id when Rumble reports one.
    func postComment(videoNumericID: String, text: String, replyTo: String?) async throws -> String? {
        guard loggedIn else { throw AccountError.notLoggedIn }
        let (data, code) = try await send(AccountRequests.addComment(videoNumericID: videoNumericID, text: text, replyTo: replyTo))
        guard code == 200 else { throw AccountError.http(code) }
        let d = try AccountRequests.parseResult(data).get()
        if let i = d["comment_id"] as? Int { return String(i) }
        return d["comment_id"] as? String
    }

    func vote(commentID: String, vote: Int) async throws {
        try await voteContent(id: commentID, type: 2, vote: vote)
    }

    /// type 1 = video/short, 2 = comment. vote: 1, -1 or 0 to clear.
    func voteContent(id: String, type: Int, vote: Int) async throws {
        guard loggedIn else { throw AccountError.notLoggedIn }
        let (data, code) = try await send(AccountRequests.vote(contentID: id, type: type, vote: vote))
        guard code == 200 else { throw AccountError.http(code) }
        _ = try AccountRequests.parseResult(data).get()
    }

    func delete(commentID: String) async throws {
        let (data, code) = try await send(AccountRequests.deleteComment(commentID))
        guard code == 200 else { throw AccountError.http(code) }
        _ = try AccountRequests.parseResult(data).get()
    }

    /// comment.list wants the embed id without its leading "v".
    func resolveCommentIDs(for video: VideoItem, known listID: String?) async throws -> String {
        if let listID { return listID }
        let d = try await RumbleService.shared.detail(for: video)
        return d.embedId.hasPrefix("v") ? String(d.embedId.dropFirst()) : d.embedId
    }

    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        var r = req
        r.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 { DiagLog.shared.request(r.url, status: code) }
            return (data, code)
        } catch {
            DiagLog.shared.request(r.url, error: error)
            throw error
        }
    }

    // MARK: - Reply alerts (best effort: iOS decides when background refresh runs)

    func setAlerts(_ on: Bool) async {
        if on {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            alertsEnabled = granted
            if granted { Self.scheduleRefresh() }
        } else {
            alertsEnabled = false
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
        }
    }

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    // MARK: - Went-live alerts

    private static let liveKey = "liveChannelIDs"

    /// Notifies about followed channels that went live since the last check (first run only records).
    func checkLive() async {
        guard loggedIn, LibraryStore.shared.data.prefs.liveAlerts,
              let chans = try? await RumbleService.shared.followedChannels() else { return }
        let stored = UserDefaults.standard.stringArray(forKey: Self.liveKey)
        let now = LiveAlertTracker.liveIDs(chans)
        UserDefaults.standard.set(Array(now), forKey: Self.liveKey)
        guard let stored else { return }
        let fresh = LiveAlertTracker.newlyLive(previous: Set(stored), current: chans)
        for c in fresh.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = "\(c.ref.name) is live"
            content.body = c.liveViewers.map { "\(CountFormat.short($0)) watching now. Tap to join." } ?? "Tap to join the stream."
            content.sound = .default
            content.threadIdentifier = "live"
            content.userInfo = ["channelPath": c.ref.path, "channelName": c.ref.name]
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "live-\(c.id)", content: content, trigger: nil))
        }
    }

    func setLiveAlerts(_ on: Bool) async {
        if on {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            LibraryStore.shared.data.prefs.liveAlerts = granted
            if granted { UserDefaults.standard.removeObject(forKey: Self.liveKey); await checkLive(); Self.scheduleRefresh() }
        } else {
            LibraryStore.shared.data.prefs.liveAlerts = false
        }
    }

    /// Called from the background refresh task.
    func backgroundCheck() async {
        let wasUnread = hasUnread
        await refreshStatus()
        if hasUnread && !wasUnread && alertsEnabled, await hasUnreadFromUnmuted() {
            let content = UNMutableNotificationContent()
            content.title = "Rumble"
            content.body = "You have new notifications — tap to see who replied."
            content.sound = .default
            content.userInfo = ["open": "inbox"]
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "rumble-unread", content: content, trigger: nil))
        }
        await checkLive()
        if alertsEnabled || LibraryStore.shared.data.prefs.liveAlerts { Self.scheduleRefresh() }
    }
}
