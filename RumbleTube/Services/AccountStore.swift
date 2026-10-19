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
        loggedIn = user?["logged_in"] as? Bool ?? false
        hasUnread = ((obj["data"] as? [String: Any])?["has_unread_notifications"] as? Bool) ?? false
        if loggedIn, username == nil, let r = try? await session.data(from: URL(string: "https://rumble.com/")!) {
            username = AccountRequests.username(fromPage: String(decoding: r.0, as: UTF8.self))
        }
        if !loggedIn { username = nil; notifications = [] }
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
        UIApplication.shared.applicationIconBadgeNumber = 0
    }

    /// Re-check unread every few minutes while the app is open.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(nanoseconds: 180_000_000_000)
            }
        }
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
        let (data, resp) = try await session.data(for: r)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
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

    /// Called from the background refresh task.
    func backgroundCheck() async {
        let wasUnread = hasUnread
        await refreshStatus()
        if hasUnread && !wasUnread && alertsEnabled {
            let content = UNMutableNotificationContent()
            content.title = "Rumble"
            content.body = "You have new notifications — tap to see who replied."
            content.sound = .default
            content.userInfo = ["open": "inbox"]
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "rumble-unread", content: content, trigger: nil))
        }
        if alertsEnabled { Self.scheduleRefresh() }
    }
}
