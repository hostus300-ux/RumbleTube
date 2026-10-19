import AVFoundation
import SwiftUI
import UIKit

// MARK: - Model: feed + a small pool of looping players

@MainActor
final class ShortsModel: ObservableObject {
    static let shared = ShortsModel()

    @Published private(set) var items: [ShortItem] = []
    @Published var index = 0 { didSet { if index != oldValue { indexChanged(from: oldValue) } } }
    @Published private(set) var muted = false
    @Published private(set) var paused = false
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var progress: Double = 0

    private var offset = 0
    private var hasMore = true
    private var active = false
    private var decidedMute = false
    private var players: [String: AVQueuePlayer] = [:]
    private var loopers: [String: AVPlayerLooper] = [:]
    private var timeObserver: (AVQueuePlayer, Any)?

    private var prefs: AppPreferences { LibraryStore.shared.data.prefs }

    // MARK: feed

    func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true
        defer { loading = false }
        do {
            var req = ShortsParser.request(offset: offset)
            req.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await RumbleHTTP.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw RumbleError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
            let page = try ShortsParser.parse(data)
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            offset += max(page.items.count, 1)
            hasMore = page.hasMore && !page.items.isEmpty
            error = nil
            if active { playCurrent() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() async {
        stopAll()
        items = []; offset = 0; hasMore = true; index = 0
        await loadMore()
    }

    // MARK: tab lifecycle

    func activate() {
        active = true
        if !decidedMute {
            decidedMute = true
            muted = prefs.shortsMutedWhenOtherAudio && AppAudio.otherAudioPlaying
        }
        if items.isEmpty { Task { await loadMore() } }
        else if prefs.autoplayShorts && !paused { playCurrent() }
    }

    func deactivate() {
        active = false
        players.values.forEach { $0.pause() }
        if !muted && !PlayerModel.shared.isPlaying { AppAudio.release() }
    }

    /// The main player is starting: Shorts go quiet.
    func pauseForMainPlayer() {
        players.values.forEach { $0.pause() }
        paused = true
    }

    // MARK: playback

    func player(for item: ShortItem) -> AVQueuePlayer {
        if let p = players[item.id] { return p }
        let q = AVQueuePlayer()
        q.isMuted = muted
        q.automaticallyWaitsToMinimizeStalling = true
        if let s = item.bestStream, let url = URL(string: s.url) {
            let asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": RumbleHTTP.userAgent, "Referer": "https://rumble.com/"],
            ])
            let template = AVPlayerItem(asset: asset)
            template.preferredForwardBufferDuration = 4
            loopers[item.id] = AVPlayerLooper(player: q, templateItem: template)
        }
        players[item.id] = q
        return q
    }

    func togglePause() {
        paused.toggle()
        if paused { currentPlayer?.pause() } else { playCurrent() }
    }

    func toggleMute() {
        muted.toggle()
        players.values.forEach { $0.isMuted = muted }
        if muted {
            if !PlayerModel.shared.isPlaying { AppAudio.release() }
        } else {
            PlayerModel.shared.player.pause()
            AppAudio.takeOver()
        }
    }

    private var currentPlayer: AVQueuePlayer? {
        items.indices.contains(index) ? players[items[index].id] : nil
    }

    private func playCurrent() {
        guard active, items.indices.contains(index) else { return }
        let item = items[index]
        let p = player(for: item)
        if !muted {
            PlayerModel.shared.player.pause()
            AppAudio.takeOver()
        }
        paused = false
        p.play()
        observeProgress(p)
        // preload the next one so swiping is instant
        if items.indices.contains(index + 1) { _ = player(for: items[index + 1]) }
    }

    private func indexChanged(from old: Int) {
        guard !items.isEmpty, items.indices.contains(index) else { return }
        if items.indices.contains(old) { players[items[old].id]?.pause() }
        progress = 0
        if prefs.autoplayShorts || !paused { playCurrent() }
        // keep only nearby players in memory
        let keep = Set((max(0, index - 1)...min(items.count - 1, index + 2)).compactMap { items.indices.contains($0) ? items[$0].id : nil })
        for id in players.keys where !keep.contains(id) {
            players[id]?.pause(); players[id] = nil; loopers[id] = nil
        }
        if index >= items.count - 3 { Task { await loadMore() } }
    }

    private func observeProgress(_ p: AVQueuePlayer) {
        if let obs = timeObserver { obs.0.removeTimeObserver(obs.1) }
        let token = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self, weak p] t in
            guard let d = p?.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
            let v = t.seconds / d
            Task { @MainActor in self?.progress = v }
        }
        timeObserver = (p, token)
    }

    private func stopAll() {
        if let obs = timeObserver { obs.0.removeTimeObserver(obs.1); timeObserver = nil }
        players.values.forEach { $0.pause() }
        players = [:]; loopers = [:]
    }

    // MARK: actions

    func vote(_ item: ShortItem, _ v: Int) async -> String? {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        let old = items[i].myVote
        let new = old == v ? 0 : v
        apply(i, old: old, new: new)
        do {
            try await AccountStore.shared.voteContent(id: item.numericID, type: 1, vote: new)
            return nil
        } catch {
            apply(i, old: new, new: old)
            return error.localizedDescription
        }
    }

    private func apply(_ i: Int, old: Int, new: Int) {
        items[i].likes += (new == 1 ? 1 : 0) - (old == 1 ? 1 : 0)
        items[i].dislikes += (new == -1 ? 1 : 0) - (old == -1 ? 1 : 0)
        items[i].myVote = new
    }
}

// MARK: - Tab

struct ShortsView: View {
    @EnvironmentObject var shorts: ShortsModel
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var router: Router
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if shorts.items.isEmpty {
                VStack(spacing: 12) {
                    if shorts.loading { ProgressView().tint(.white) }
                    if let e = shorts.error {
                        Text(e).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                        Button("Try again") { Task { await shorts.refresh() } }.buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            } else {
                VerticalPager(count: shorts.items.count, index: $shorts.index) { i in
                    ShortPage(item: shorts.items[i], isCurrent: i == shorts.index)
                        .environmentObject(shorts).environmentObject(account).environmentObject(library)
                        .environmentObject(router).environmentObject(player)
                        .tint(Color.rumbleGreen)
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
    }
}

// MARK: - One short

struct ShortPage: View {
    let item: ShortItem
    let isCurrent: Bool
    @EnvironmentObject var shorts: ShortsModel
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var router: Router
    @EnvironmentObject var player: PlayerModel
    @State private var showComments = false
    @State private var showLogin = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.black
            ShortSurface(player: shorts.player(for: item))
                .contentShape(Rectangle())
                .onTapGesture { shorts.togglePause() }
            if isCurrent && shorts.paused {
                Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.85))
                    .allowsHitTesting(false)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack {
                HStack {
                    Text("Shorts").font(.title3.weight(.bold))
                    Spacer()
                    Button { shorts.toggleMute() } label: {
                        Image(systemName: shorts.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.title3).padding(10).background(.black.opacity(0.35), in: Circle())
                    }
                }
                .padding(.horizontal, 16).padding(.top, 54)
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    info
                    Spacer(minLength: 8)
                    actions
                }
                .padding(.horizontal, 14).padding(.bottom, 18)
                if isCurrent {
                    GeometryReader { g in
                        Rectangle().fill(Color.white.opacity(0.85)).frame(width: g.size.width * min(1, shorts.progress))
                    }
                    .frame(height: 2)
                }
            }
            .foregroundStyle(.white)
            if let t = toast {
                Text(t).font(.footnote.weight(.semibold)).padding(10).background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .sheet(isPresented: $showComments) {
            NavigationStack {
                CommentsScreen(target: CommentTarget(video: item.asVideoItem, listID: item.commentListID,
                                                     videoNumericID: item.numericID, focusCommentID: nil))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showComments = false } } }
            }
            .environmentObject(account).environmentObject(player).environmentObject(library).environmentObject(router)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(account) }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let c = item.channel {
                HStack(spacing: 8) {
                    Button { router.open(c) } label: {
                        HStack(spacing: 8) {
                            ChannelAvatar(name: c.name, url: c.avatar, size: 32)
                            Text(c.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                    }
                    let following = library.data.isFollowing(c.path)
                    Button(following ? "Following" : "Follow") { library.data.toggleFollow(c) }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(following ? Color.white.opacity(0.2) : Color.white, in: Capsule())
                        .foregroundStyle(following ? Color.white : Color.black)
                }
            }
            Text(item.title).font(.subheadline).lineLimit(3)
        }
    }

    private var actions: some View {
        VStack(spacing: 18) {
            actionButton(item.myVote == 1 ? "hand.thumbsup.fill" : "hand.thumbsup", CountFormat.short(item.likes),
                         tint: item.myVote == 1 ? Color.rumbleGreen : .white) { vote(1) }
            actionButton(item.myVote == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown", CountFormat.short(item.dislikes),
                         tint: item.myVote == -1 ? .red : .white) { vote(-1) }
            actionButton("text.bubble", CountFormat.short(item.comments), tint: .white) { showComments = true }
            if let url = URL(string: item.url) {
                ShareLink(item: url) {
                    VStack(spacing: 3) { Image(systemName: "arrowshape.turn.up.right").font(.title2); Text("Share").font(.caption2) }
                }
            }
        }
    }

    private func actionButton(_ icon: String, _ label: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title2).foregroundStyle(tint)
                Text(label).font(.caption2.weight(.semibold))
            }
        }
    }

    private func vote(_ v: Int) {
        guard account.loggedIn else { showLogin = true; return }
        Task {
            if let e = await shorts.vote(item, v) {
                toast = e
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                toast = nil
            }
        }
    }
}

struct ShortSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspectFill
        v.playerLayer.player = player
        return v
    }
    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

// MARK: - Vertical paging (UIPageViewController — smooth on iOS 16+)

struct VerticalPager<Page: View>: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    let page: (Int) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .vertical)
        pvc.view.backgroundColor = .black
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.setViewControllers([context.coordinator.host(index)], direction: .forward, animated: false)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        if let current = pvc.viewControllers?.first as? Host {
            if current.index != index {
                pvc.setViewControllers([context.coordinator.host(index)], direction: .forward, animated: false)
            } else {
                current.rootView = AnyView(page(index))
            }
        }
    }

    final class Host: UIHostingController<AnyView> {
        var index = 0
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: VerticalPager
        init(_ parent: VerticalPager) { self.parent = parent }

        func host(_ i: Int) -> Host {
            let h = Host(rootView: AnyView(parent.page(i)))
            h.index = i
            h.view.backgroundColor = .black
            return h
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let h = vc as? Host, h.index > 0 else { return nil }
            return host(h.index - 1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let h = vc as? Host, h.index + 1 < parent.count else { return nil }
            return host(h.index + 1)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let h = pvc.viewControllers?.first as? Host else { return }
            parent.index = h.index
        }
    }
}
