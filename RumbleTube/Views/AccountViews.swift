import SwiftUI
import UserNotifications
import WebKit

// MARK: - Sign in (Rumble's own page; we never see the password)

/// Page-load state for the sign-in screen, kept separate so the web view itself isn't redrawn as it loads.
@MainActor
final class LoginPageState: ObservableObject {
    @Published var progress: Double = 0
    @Published var host = "rumble.com"
    @Published var firstPageLoaded = false
}

struct LoginView: View {
    @EnvironmentObject var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var page = LoginPageState()
    @State private var checking = false
    @State private var success = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LoginHeader(page: page)
                ZStack {
                    LoginWebView(page: page, onNavigate: handle)
                    if !page.firstPageLoaded && !success {
                        Color(.systemBackground)
                        ProgressView()
                    }
                    if success {
                        Color(.systemBackground)
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Color.rumbleGreen)
                                .transition(.scale.combined(with: .opacity))
                            Text(account.username.map { "Signed in as \($0)" } ?? "Signed in").font(.headline)
                        }
                    }
                    if checking && !success {
                        ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Sign in to Rumble")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .interactiveDismissDisabled(checking)
    }

    /// After the first sign-in, ask once to turn on reply and went-live alerts (on by default if you allow them).
    @MainActor static func offerNotifications(_ account: AccountStore) async {
        let key = "askedAlertsAfterSignIn"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? await Task.sleep(nanoseconds: 600_000_000)   // let the sign-in sheet finish closing
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        guard granted else { return }
        account.alertsEnabled = true
        await account.setLiveAlerts(true)
        AccountStore.scheduleRefresh()
    }

    private func handle(_ url: URL) {
        // Back on rumble.com (not the auth pages) → check whether we're signed in.
        guard let host = url.host, host == "rumble.com" || host == "www.rumble.com",
              !url.path.contains("login"), !checking else { return }
        checking = true
        Task {
            await account.refreshStatus()
            checking = false
            if account.loggedIn {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // Pull your Rumble history, profile and follows right away (not on the next periodic sync).
                Task { await WatchHistorySync.shared.sync(force: true) }
                Task { await account.loadProfile() }
                Task { await MyFeedModel.shared.refreshChannels(force: true) }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { success = true }
                try? await Task.sleep(nanoseconds: 900_000_000)
                dismiss()
                await Self.offerNotifications(account)
            }
        }
    }
}

/// One slim strip under the title: the page you're really on (with a lock), what happens with your password,
/// and a thin load bar. It never pushes the form around.
private struct LoginHeader: View {
    @ObservedObject var page: LoginPageState

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label(page.host, systemImage: "lock.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Text("Your password goes only to Rumble.").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 16)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.clear)
                GeometryReader { g in
                    Rectangle().fill(Color.rumbleGreen)
                        .frame(width: g.size.width * page.progress)
                        .opacity(page.progress > 0 && page.progress < 1 ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: page.progress)
                }
            }
            .frame(height: 2)
        }
        .padding(.top, 2)
    }
}

struct LoginWebView: UIViewRepresentable {
    let page: LoginPageState
    var onNavigate: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(page: page, onNavigate: onNavigate) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.addUserScript(WKUserScript(source: Self.cookieBannerScript,
                                                                 injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        config.userContentController.addUserScript(WKUserScript(source: Self.focusScript,
                                                                 injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = RumbleHTTP.userAgent
        web.backgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        context.coordinator.observe(web)
        web.load(URLRequest(url: URL(string: "https://rumble.com/login.php")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// On Rumble's sign-in pages, hide the site's own header, menu and footer so only the form shows.
    static let focusScript = """
    (function () {
      // Only Rumble's own sign-in pages (never Apple's or Google's).
      if (!/(^|\\.)rumble\\.com$/i.test(location.host) || !/login|register|auth|password|sso/i.test(location.pathname + location.host)) return;
      function tidy() {
        var sel = 'header, footer, .header, .footer, .main-menu, [data-js=main_menu], .header-div, .sidebar, .app-banner, .smart-banner';
        document.querySelectorAll(sel).forEach(function (el) {
          // Never hide anything that holds the sign-in form itself.
          if (!el.querySelector('input, form, button[type=submit]')) el.style.setProperty('display', 'none', 'important');
        });
      }
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', tidy); else tidy();
      setTimeout(tidy, 800);
    })();
    """

    /// Rumble's cookie consent pop-up (OneTrust) covers the sign-in form. This answers it with
    /// "Reject All" (only essential cookies, which sign-in needs) and hides it, on every page of the flow.
    static let cookieBannerScript = """
    (function () {
      // Hide the known consent tools right away (OneTrust and similar).
      var css = document.createElement('style');
      css.textContent = '#onetrust-consent-sdk,#onetrust-banner-sdk,.onetrust-pc-dark-filter,#ot-sdk-btn-floating,' +
        '#usercentrics-root,#CybotCookiebotDialog,.fc-consent-root,#qc-cmp2-container{display:none!important}' +
        'html,body{overflow:auto!important}';
      (document.head || document.documentElement).appendChild(css);
      function reject() {
        // Any consent dialog: press its "Reject All" button (keeps only the cookies sign-in needs).
        var btns = document.querySelectorAll('button, a, [role=button]');
        for (var i = 0; i < btns.length; i++) {
          var t = (btns[i].innerText || btns[i].textContent || '').trim().toLowerCase();
          if (t === 'reject all' || t === 'reject all cookies' || t === 'decline all' || t === 'only necessary') {
            btns[i].click();
            return true;
          }
        }
        return false;
      }
      function hide() {
        // Fallback: hide any fixed overlay that is a cookie notice.
        var all = document.querySelectorAll('div, section, aside, dialog');
        for (var i = 0; i < all.length; i++) {
          var el = all[i], cs = getComputedStyle(el);
          if ((cs.position === 'fixed' || cs.position === 'sticky') &&
              /we value your privacy|cookie/i.test((el.innerText || '').slice(0, 300)) &&
              /accept all|reject all/i.test(el.innerText || '')) { el.style.setProperty('display', 'none', 'important'); }
        }
      }
      var tries = 0;
      var timer = setInterval(function () {
        tries++;
        if (reject() || tries > 60) { clearInterval(timer); }
        if (tries % 4 === 0) hide();
      }, 250);
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let page: LoginPageState
        let onNavigate: (URL) -> Void
        private var observations: [NSKeyValueObservation] = []
        init(page: LoginPageState, onNavigate: @escaping (URL) -> Void) {
            self.page = page; self.onNavigate = onNavigate
        }

        func observe(_ web: WKWebView) {
            observations = [
                web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                    let p = (w.estimatedProgress * 20).rounded() / 20      // 5% steps: fewer redraws
                    Task { @MainActor in if let s = self, s.page.progress != p { s.page.progress = p } }
                },
                web.observe(\.url, options: [.new]) { [weak self] w, _ in
                    guard let h = w.url?.host else { return }
                    let host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
                    Task { @MainActor in if let s = self, s.page.host != host { s.page.host = host } }
                },
            ]
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !page.firstPageLoaded { page.firstPageLoaded = true }
            if let url = webView.url { onNavigate(url) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !page.firstPageLoaded { page.firstPageLoaded = true }
        }

        // "Sign in with Apple/Google" pop-ups: open them in the same view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}

// MARK: - Inbox

/// What the comments screen should show.
struct CommentTarget: Hashable {
    var video: VideoItem
    var listID: String?
    var videoNumericID: String?
    /// The comment to bring up (e.g. the reply from a notification).
    var focusCommentID: String?
}

struct InboxView: View {
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var router: Router
    @State private var showLogin = false

    private var groups: [(String, [RumbleNotification])] {
        let cal = Calendar.current
        var today: [RumbleNotification] = [], week: [RumbleNotification] = [], earlier: [RumbleNotification] = []
        let lib = LibraryStore.shared.data
        for n in account.notifications where lib.muteEntry(path: n.actorPath, name: n.actorName) == nil {
            guard let d = n.createdOn else { earlier.append(n); continue }
            if cal.isDateInToday(d) { today.append(n) }
            else if Date().timeIntervalSince(d) < 7 * 86400 { week.append(n) }
            else { earlier.append(n) }
        }
        return [("Today", today), ("This week", week), ("Earlier", earlier)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        Group {
            if !account.loggedIn {
                VStack(spacing: 14) {
                    Image(systemName: "bell.badge").font(.system(size: 46)).foregroundStyle(Color.rumbleGreen)
                    Text("Your Rumble notifications").font(.title3.weight(.semibold))
                    Text("Sign in to see replies and jump straight to the comment — no scrolling.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Sign in to Rumble") { showLogin = true }
                        .buttonStyle(.borderedProminent).tint(.rumbleGreen).foregroundStyle(.black)
                }
                .padding(40)
            } else {
                List {
                    if let e = account.notificationsError {
                        Text(e).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(groups, id: \.0) { g in
                        Section {
                            ForEach(g.1) { n in
                                row(n)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(n.read ? Color.clear : Color.rumbleGreen.opacity(0.08))
                            }
                        } header: {
                            Text(g.0).font(.headline).foregroundStyle(.primary).textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if account.loadingNotifications && account.notifications.isEmpty { ProgressView() }
                    else if !account.loadingNotifications && account.notifications.isEmpty && account.notificationsError == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "bell.slash").font(.largeTitle).foregroundStyle(.secondary)
                            Text("You're all caught up.").foregroundStyle(.secondary)
                        }
                    }
                }
                .pullToRefresh { await account.loadNotifications() }
                .task { await account.loadNotifications() }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerSpace()
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(account) }
    }

    private func message(_ n: RumbleNotification) -> Text {
        guard let name = n.actorName, !name.isEmpty else { return Text(n.body) }
        var rest = n.body
        if rest.lowercased().hasPrefix(name.lowercased()) { rest = String(rest.dropFirst(name.count)) }
        else { rest = " · " + rest }
        return Text(name).fontWeight(.bold) + Text(rest)
    }

    private func icon(_ n: RumbleNotification) -> (String, Color) {
        let t = n.type.lowercased()
        if t.contains("reply") || t.contains("comment") { return ("bubble.left.fill", .blue) }
        if t.contains("mention") { return ("at", .purple) }
        if t.contains("rumble") || t.contains("like") || t.contains("vote") { return ("hand.thumbsup.fill", .rumbleGreen) }
        if t.contains("follow") || t.contains("subscri") { return ("person.fill.badge.plus", .orange) }
        if t.contains("live") { return ("dot.radiowaves.left.and.right", Color.rumbleRed) }
        if t.contains("rant") || t.contains("tip") { return ("dollarsign", .yellow) }
        return ("bell.fill", .gray)
    }

    @ViewBuilder private func row(_ n: RumbleNotification) -> some View {
        let ic = icon(n)
        let content = HStack(alignment: .top, spacing: 12) {
            ChannelAvatar(name: n.actorName ?? "R", url: n.actorAvatar, size: 44)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: ic.0).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 19, height: 19).background(ic.1, in: Circle())
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2)).offset(x: 4, y: 4)
                }
            VStack(alignment: .leading, spacing: 4) {
                message(n).font(.subheadline).lineLimit(3).multilineTextAlignment(.leading)
                Text(n.createdText ?? n.createdOn.map { DateParsing.relative($0) } ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let v = n.video {
                Thumbnail(item: v).frame(width: 76).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if !n.read { Circle().fill(Color.rumbleGreen).frame(width: 8, height: 8).padding(.top, 18) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())

        if let v = n.video, n.isCommentRelated {
            NavigationLink(value: CommentTarget(video: v, listID: n.commentListID, videoNumericID: n.videoNumericID,
                                                focusCommentID: n.commentID)) { content }
                .buttonStyle(.plain)
        } else if let v = n.video {
            Button { player.play(v) } label: { content }.buttonStyle(.plain)
        } else if let p = n.actorPath {
            NavigationLink(value: ChannelRef(path: p, name: n.actorName ?? p, avatar: n.actorAvatar)) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - Comments (thread focus + full list + reply)

@MainActor
final class CommentsModel: ObservableObject {
    @Published var page: CommentPage?
    @Published var loading = false
    @Published var error: String?
    @Published var sort = "rumbles"
    @Published var myVotes: [String: Int] = [:]
    @Published var expanded: Set<String> = []
    var listID: String?
    var numericID: String?
    let target: CommentTarget

    init(target: CommentTarget) {
        self.target = target
        listID = target.listID
        numericID = target.videoNumericID
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let id = try await AccountStore.shared.resolveCommentIDs(for: target.video, known: listID)
            listID = id
            let p = try await AccountStore.shared.comments(listID: id, sort: sort == "rumbles" ? nil : sort)
            page = p
            if numericID == nil { numericID = p.videoNumericID }
            if let f = target.focusCommentID, let path = p.path(to: f) { expanded.formUnion(path) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Show a comment as deleted right away (Rumble keeps it as "[deleted]" so replies stay threaded).
    func markDeleted(_ id: String) {
        guard var p = page else { return }
        func fix(_ c: inout RumbleComment) {
            if c.id == id { c.text = "[deleted]"; c.actions.removeAll { $0 == "delete" }; return }
            for i in c.replies.indices { fix(&c.replies[i]) }
        }
        for i in p.comments.indices { fix(&p.comments[i]) }
        page = p
    }

    func adjust(_ id: String, up: Int, down: Int) {
        guard var p = page else { return }
        func fix(_ c: inout RumbleComment) {
            if c.id == id { c.upVotes += up; c.downVotes += down; return }
            for i in c.replies.indices { fix(&c.replies[i]) }
        }
        for i in p.comments.indices { fix(&p.comments[i]) }
        page = p
    }
}

struct CommentsScreen: View {
    let target: CommentTarget
    @StateObject private var model: CommentsModel
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var player: PlayerModel
    @State private var draft = ""
    @State private var replyTo: RumbleComment?
    @State private var sending = false
    @State private var toast: String?
    @State private var showAll = false
    @State private var showLogin = false
    @FocusState private var composerFocused: Bool
    @Environment(\.dismiss) private var dismissComments
    /// Shown inside the player (no video header, timestamp taps just seek).
    var inline = false

    init(target: CommentTarget, inline: Bool = false) {
        self.target = target
        self.inline = inline
        _model = StateObject(wrappedValue: CommentsModel(target: target))
    }

    private var focused: RumbleComment? { target.focusCommentID.flatMap { model.page?.comment($0) } }
    private var thread: RumbleComment? { target.focusCommentID.flatMap { model.page?.thread(containing: $0) } }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !inline { videoHeader }
                if let e = model.error {
                    Section { Text(e).foregroundStyle(.secondary); Button("Try again") { Task { await model.load() } } }
                }
                if let thread {
                    Section {
                        commentTree(thread, depth: 0)
                    } header: {
                        Text("Your thread")
                    }
                    Section {
                        Button(showAll ? "Hide other comments" : "Show all \(model.page?.totalText ?? "comments")") {
                            withAnimation { showAll.toggle() }
                        }
                    }
                } else if target.focusCommentID != nil, model.page != nil {
                    Section {
                        Text("Couldn't find that comment — it may have been deleted. Showing all comments.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if thread == nil || showAll, let page = model.page {
                    Section {
                        ForEach(page.comments.filter { $0.id != thread?.id }) { c in commentTree(c, depth: 0) }
                    } header: {
                        HStack {
                            Text(page.totalText ?? "Comments")
                            Spacer()
                            Picker("Sort", selection: $model.sort) {
                                Text("Top").tag("rumbles"); Text("Newest").tag("date")
                            }
                            .pickerStyle(.menu)
                            .onChange(of: model.sort) { _ in Task { await model.load() } }
                        }
                    }
                }
                if model.loading && model.page == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .pullToRefresh { await model.load() }
            .task {
                if model.page == nil {
                    await model.load()
                    if let f = target.focusCommentID, model.page?.comment(f) != nil {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        withAnimation { proxy.scrollTo(f, anchor: .center) }
                        if let c = focused, c.canReply, account.loggedIn { replyTo = c }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("Comments")
        .seekLinks(for: target.video, player: player, onSeek: { if !inline { dismissComments() } })
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let t = toast {
                Text(t).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.rumbleGreen, in: Capsule()).foregroundStyle(.black).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: toast)
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(account) }
    }

    // MARK: pieces

    private var videoHeader: some View {
        Button { player.play(target.video) } label: {
            HStack(spacing: 10) {
                Thumbnail(item: target.video).frame(width: 110).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let c = target.video.channelName { Text(c).font(.caption).foregroundStyle(.secondary) }
                    Label("Watch", systemImage: "play.fill").font(.caption.weight(.semibold)).foregroundStyle(Color.rumbleGreen)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func commentTree(_ c: RumbleComment, depth: Int) -> AnyView {
        AnyView(Group {
            CommentRow(comment: c, depth: depth, highlighted: c.id == target.focusCommentID,
                       isMine: account.username.map { $0.caseInsensitiveCompare(c.author) == .orderedSame } ?? false,
                       myVote: model.myVotes[c.id] ?? 0,
                       onVote: { v in Task { await vote(c, v) } },
                       onReply: { startReply(c) },
                       onDelete: { Task { await delete(c) } },
                       onRestore: { Task { await restore(c) } })
                .id(c.id)
            if !c.replies.isEmpty {
                if model.expanded.contains(c.id) {
                    ForEach(c.replies) { r in commentTree(r, depth: depth + 1) }
                } else {
                    Button("Show \(c.replies.count) repl\(c.replies.count == 1 ? "y" : "ies")") {
                        withAnimation { _ = model.expanded.insert(c.id) }
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.leading, CGFloat(depth + 1) * 18)
                }
            }
        })
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !account.loggedIn {
                Button("Sign in to comment and reply") { showLogin = true }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                if let r = replyTo {
                    HStack {
                        Text("Replying to ").foregroundColor(.secondary) + Text("@\(r.author)").bold()
                        Spacer()
                        Button { replyTo = nil } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    // Insert the video's current position, e.g. "12:34 ", so the comment can point at a moment.
                    if player.item?.id == target.video.id, !player.isLive {
                        Button {
                            let stamp = TimeFormat.clock(player.currentTime)
                            let sep = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
                            draft += sep + stamp + " "
                            composerFocused = true
                        } label: {
                            Image(systemName: "clock.badge").font(.system(size: 20))
                                .frame(width: 34, height: 36)
                        }
                        .accessibilityLabel("Add timestamp")
                    }
                    TextField(replyTo == nil ? "Add a comment…" : "Write a reply…", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                    Button { Task { await send() } } label: {
                        Image(systemName: sending ? "hourglass" : "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || model.numericID == nil)
                }
                if draft.count > 1800 { Text("\(draft.count)/2000").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: actions

    private func startReply(_ c: RumbleComment) {
        guard account.loggedIn else { showLogin = true; return }
        replyTo = c
        composerFocused = true
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let vid = model.numericID else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await account.postComment(videoNumericID: vid, text: String(text.prefix(2000)), replyTo: replyTo?.id)
            if let r = replyTo { model.expanded.insert(r.id) }
            draft = ""; replyTo = nil; composerFocused = false
            show("Posted")
            await model.load()
        } catch {
            show(error.localizedDescription)
        }
    }

    private func vote(_ c: RumbleComment, _ v: Int) async {
        guard account.loggedIn else { showLogin = true; return }
        let old = model.myVotes[c.id] ?? 0
        let new = old == v ? 0 : v
        model.myVotes[c.id] = new
        model.adjust(c.id, up: (new == 1 ? 1 : 0) - (old == 1 ? 1 : 0), down: (new == -1 ? 1 : 0) - (old == -1 ? 1 : 0))
        do { try await account.vote(commentID: c.id, vote: new) } catch {
            model.myVotes[c.id] = old
            model.adjust(c.id, up: (old == 1 ? 1 : 0) - (new == 1 ? 1 : 0), down: (old == -1 ? 1 : 0) - (new == -1 ? 1 : 0))
            show(error.localizedDescription)
        }
    }

    private func delete(_ c: RumbleComment) async {
        func gone() -> Bool {
            guard let still = model.page?.comment(c.id) else { return true }
            return still.isDeleted || !still.canDelete
        }
        do {
            try await account.delete(commentID: c.id)
            model.markDeleted(c.id)
            // Check with Rumble (it answers OK even when it ignored a request); if it didn't take, try a form post.
            try? await Task.sleep(nanoseconds: 700_000_000)
            await model.load()
            if !gone() {
                try await account.delete(commentID: c.id, post: true)
                try? await Task.sleep(nanoseconds: 700_000_000)
                await model.load()
            }
            if gone() { model.markDeleted(c.id); show("Deleted") }
            else { show("Rumble didn't delete it. Try again in a moment.") }
        } catch {
            show(error.localizedDescription)
        }
    }

    private func restore(_ c: RumbleComment) async {
        do { try await account.restore(commentID: c.id); await model.load(); show("Restored") }
        catch { show(error.localizedDescription) }
    }

    private func show(_ s: String) {
        toast = s
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if toast == s { toast = nil } }
    }
}

struct CommentRow: View {
    let comment: RumbleComment
    let depth: Int
    let highlighted: Bool
    let isMine: Bool
    let myVote: Int
    var onVote: (Int) -> Void
    var onReply: () -> Void
    var onDelete: () -> Void
    var onRestore: () -> Void = {}
    @State private var confirmingDelete = false
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var mute = MuteUI.shared

    private var muteEntry: MutedEntry? {
        isMine ? nil : library.data.muteEntry(path: comment.authorPath, name: comment.author)
    }

    var body: some View {
        if let e = muteEntry, !mute.revealed.contains(comment.id) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.slash.fill").foregroundStyle(.secondary)
                    .frame(width: depth == 0 ? 34 : 28)
                VStack(alignment: .leading, spacing: 5) {
                    MuteBadge(tag: e.tag)
                    Text("Comment from a user you muted").font(.footnote).foregroundStyle(.secondary)
                    Button("Show anyway") { withAnimation { _ = mute.revealed.insert(comment.id) } }
                        .font(.caption.weight(.semibold)).buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(min(depth, 4)) * 18)
            .padding(.vertical, 4)
            .contextMenu {
                Button { mute.muteUser(comment) } label: { Label("Edit mute tag", systemImage: "tag") }
                Button(role: .destructive) { library.data.unmute(e.key) } label: { Label("Unmute \(comment.author)", systemImage: "speaker.wave.2") }
            }
        } else {
            full
        }
    }

    private var full: some View {
        HStack(alignment: .top, spacing: 10) {
            ChannelAvatar(name: comment.author, url: comment.avatar, size: depth == 0 ? 34 : 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(comment.author).font(.footnote.weight(.semibold))
                    if comment.isVideoOwner { tag("Creator", .rumbleGreen) }
                    if isMine { tag("You", .blue) }
                    if comment.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text("· \(comment.timeText)").font(.caption).foregroundStyle(.secondary)
                }
                // No text selection here: it swallows taps on timestamp links.
                if comment.isDeleted {
                    Text("[deleted]").font(.subheadline).italic().foregroundStyle(.secondary)
                } else {
                    Text(SeekLinks.attributed(comment.text)).font(.subheadline)
                }
                HStack(spacing: 18) {
                    Button { onVote(1) } label: {
                        Label("\(comment.upVotes)", systemImage: myVote == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    .foregroundStyle(myVote == 1 ? Color.rumbleGreen : .secondary)
                    Button { onVote(-1) } label: {
                        Label("\(comment.downVotes)", systemImage: myVote == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                    .foregroundStyle(myVote == -1 ? Color.red : .secondary)
                    if comment.canReply { Button("Reply", action: onReply).foregroundStyle(.secondary) }
                    if comment.canDelete && !comment.isDeleted {
                        // The confirmation pops up from the Delete button itself.
                        Button("Delete", role: .destructive) { confirmingDelete = true }
                            .confirmationDialog("Delete this comment?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                                Button("Delete", role: .destructive, action: onDelete)
                            }
                    }
                    if isMine && comment.actions.contains("restore") { Button("Restore", action: onRestore) }
                    if !isMine {
                        Spacer(minLength: 0)
                        Menu {
                            if let e = library.data.muteEntry(path: comment.authorPath, name: comment.author) {
                                Button { mute.muteUser(comment) } label: { Label("Edit mute tag", systemImage: "tag") }
                                Button(role: .destructive) { library.data.unmute(e.key) } label: { Label("Unmute \(comment.author)", systemImage: "speaker.wave.2") }
                            } else {
                                Button { mute.muteUser(comment) } label: { Label("Mute \(comment.author)…", systemImage: "speaker.slash") }
                            }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 28, height: 20).contentShape(Rectangle())
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderless)
            }
        }
        .padding(.leading, CGFloat(min(depth, 4)) * 18)
        .padding(.vertical, 4)
        .listRowBackground(highlighted ? Color.rumbleGreen.opacity(0.18) : nil)
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.2), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(c)
    }
}

// MARK: - Settings section

struct AccountSettingsSection: View {
    @EnvironmentObject var account: AccountStore
    @State private var showLogin = false

    var body: some View {
        Section {
            if account.loggedIn {
                LabeledContent("Signed in as", value: account.username ?? "Rumble user")
                Toggle("Alert me about new notifications", isOn: Binding(
                    get: { account.alertsEnabled },
                    set: { v in Task { await account.setAlerts(v) } }))
                Toggle("Alert me when channels I follow go live", isOn: Binding(
                    get: { LibraryStore.shared.data.prefs.liveAlerts },
                    set: { v in Task { await account.setLiveAlerts(v) } }))
                Button("Sign out", role: .destructive) { Task { await account.signOut() } }
            } else {
                Button("Sign in to Rumble") { showLogin = true }
            }
        } header: {
            Text("Rumble account")
        } footer: {
            Text(account.loggedIn
                 ? "Alerts check in the background when iOS allows it, so they can be delayed."
                 : "You sign in on Rumble's own page. RumbleTube keeps only the session cookie on this phone.")
        }
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(account) }
    }
}
