import SwiftUI
import WebKit

// MARK: - Sign in (Rumble's own page; we never see the password)

struct LoginView: View {
    @EnvironmentObject var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        NavigationStack {
            LoginWebView { url in
                // Back on rumble.com (not the auth pages) → check whether we're signed in.
                guard let host = url.host, host == "rumble.com" || host == "www.rumble.com",
                      !url.path.contains("login") else { return }
                checking = true
                Task {
                    await account.refreshStatus()
                    checking = false
                    if account.loggedIn { dismiss() }
                }
            }
            .overlay { if checking { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
            .navigationTitle("Sign in to Rumble")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await account.refreshStatus(); dismiss() } }
                }
            }
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    var onNavigate: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNavigate: onNavigate) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = RumbleHTTP.userAgent
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: URL(string: "https://rumble.com/login.php")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onNavigate: (URL) -> Void
        init(onNavigate: @escaping (URL) -> Void) { self.onNavigate = onNavigate }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url { onNavigate(url) }
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
                    ForEach(account.notifications) { n in
                        row(n)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if account.loadingNotifications && account.notifications.isEmpty { ProgressView() }
                    else if !account.loadingNotifications && account.notifications.isEmpty && account.notificationsError == nil {
                        Text("No notifications yet.").foregroundStyle(.secondary)
                    }
                }
                .refreshable { await account.loadNotifications() }
                .task { await account.loadNotifications() }
            }
        }
        .navigationTitle("Inbox")
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(account) }
    }

    @ViewBuilder private func row(_ n: RumbleNotification) -> some View {
        let content = HStack(alignment: .top, spacing: 10) {
            ChannelAvatar(name: n.actorName ?? "R", url: n.actorAvatar, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(n.body).font(.subheadline.weight(n.read ? .regular : .semibold)).lineLimit(3)
                HStack(spacing: 6) {
                    if !n.read { Circle().fill(Color.rumbleGreen).frame(width: 7, height: 7) }
                    Text(n.createdText ?? n.createdOn.map { DateParsing.relative($0) } ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                    if n.commentID != nil {
                        Label("Open comment", systemImage: "text.bubble").font(.caption.weight(.medium))
                            .foregroundStyle(Color.rumbleGreen)
                    }
                }
            }
            Spacer(minLength: 4)
            if let v = n.video {
                Thumbnail(item: v).frame(width: 88).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 4)

        if let v = n.video, n.isCommentRelated {
            NavigationLink(value: CommentTarget(video: v, listID: n.commentListID, videoNumericID: n.videoNumericID,
                                                focusCommentID: n.commentID)) { content }
        } else if let v = n.video {
            Button { player.play(v) } label: { content }.buttonStyle(.plain)
        } else if let p = n.actorPath {
            NavigationLink(value: ChannelRef(path: p, name: n.actorName ?? p, avatar: n.actorAvatar)) { content }
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
    @State private var confirmDelete: RumbleComment?
    @FocusState private var composerFocused: Bool

    init(target: CommentTarget) {
        self.target = target
        _model = StateObject(wrappedValue: CommentsModel(target: target))
    }

    private var focused: RumbleComment? { target.focusCommentID.flatMap { model.page?.comment($0) } }
    private var thread: RumbleComment? { target.focusCommentID.flatMap { model.page?.thread(containing: $0) } }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                videoHeader
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
            .refreshable { await model.load() }
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
        .confirmationDialog("Delete this comment?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let c = confirmDelete { Task { await delete(c) } }
            }
        }
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
                       onDelete: { confirmDelete = c })
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
        do { try await account.delete(commentID: c.id); show("Deleted"); await model.load() }
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

    var body: some View {
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
                Text(comment.text).font(.subheadline).textSelection(.enabled)
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
                    if comment.canDelete { Button("Delete", role: .destructive, action: onDelete) }
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
