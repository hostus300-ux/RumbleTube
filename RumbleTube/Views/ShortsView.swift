import AVFoundation
import SwiftUI
import UIKit

// MARK: - Model: feed + a small pool of looping players

@MainActor
final class ShortsModel: ObservableObject {
    static let shared = ShortsModel()

    enum Source: String, CaseIterable { case following = "Following", all = "For You" }
    @Published private(set) var source: Source
    /// The other feed's state, kept so flipping Following / For You is instant.
    private var parked: [Source: (items: [ShortItem], offset: Int, hasMore: Bool, index: Int)] = [:]
    private static let instances = NSHashTable<ShortsModel>.weakObjects()
    init(source: Source = .all) {
        self.source = source
        Self.instances.add(self)
    }
    /// Pause every Shorts feed (main tab and followed-creators) when the main player starts.
    static func pauseAll() { instances.allObjects.forEach { $0.pauseForMainPlayer() } }

    @Published private(set) var items: [ShortItem] = []
    @Published var index = 0 { didSet { if index != oldValue { indexChanged(from: oldValue) } } }
    @Published private(set) var muted = false
    @Published private(set) var paused = false
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    /// Held down for 2× speed.
    @Published private(set) var fast = false
    /// Shorts you said you're not interested in (this session); swiped past and not shown again.
    @Published private(set) var hidden: Set<String> = []

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
        let asked = source
        do {
            var req = source == .all ? ShortsParser.request(offset: offset) : FollowingAPI.feedRequest(pill: "shorts", offset: offset, limit: 12)
            req.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
            if source == .following { req.setValue("https://rumble.com/subscriptions", forHTTPHeaderField: "Referer") }
            let (data, resp) = try await RumbleHTTP.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw RumbleError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
            guard asked == source else { return }   // you flipped feeds while this was loading
            let page: ShortsPage
            if source == .all {
                page = try ShortsParser.parse(data)
            } else {
                let f = try FollowingAPI.parseFeed(data)
                page = ShortsPage(items: f.raw.compactMap(ShortsParser.item), hasMore: f.hasMore && !f.raw.isEmpty)
                if page.items.isEmpty && items.isEmpty && !page.hasMore { error = "No shorts from channels you follow yet." }
            }
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) && !hidden.contains($0.id) }
            offset += max(page.items.count, 1)
            hasMore = page.hasMore && !page.items.isEmpty
            if !page.items.isEmpty { error = nil }
            if active { playCurrent() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Flip between Following and For You, keeping each feed's place.
    func switchSource(_ s: Source) {
        guard s != source else { return }
        players.values.forEach { $0.pause() }
        parked[source] = (items, offset, hasMore, index)
        stopAll()
        let p = parked[s]
        source = s
        items = p?.items ?? []; offset = p?.offset ?? 0; hasMore = p?.hasMore ?? true
        index = p?.index ?? 0
        progress = 0; error = nil; paused = false
        if items.isEmpty { Task { await loadMore() } } else if active { playCurrent() }
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

    /// A muted channel's short stays covered (and silent) until you tap Show anyway.
    func isCovered(_ item: ShortItem) -> Bool {
        LibraryStore.shared.data.muteEntry(path: item.channel?.path, name: item.channel?.name) != nil
            && !MuteUI.shared.revealed.contains(item.id)
    }

    func reveal(_ item: ShortItem) {
        MuteUI.shared.revealed.insert(item.id)
        if items.indices.contains(index), items[index].id == item.id { playCurrent() }
    }

    func setFast(_ on: Bool) {
        fast = on
        guard let p = currentPlayer, !paused else { return }
        p.rate = on ? 2 : 1
    }

    func seek(to fraction: Double) {
        guard let p = currentPlayer, duration > 0 else { return }
        let t = CMTime(seconds: max(0, min(1, fraction)) * duration, preferredTimescale: 600)
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
        progress = fraction
    }

    /// "Not interested": skip ahead and never show it again this session.
    func notInterested(_ item: ShortItem) {
        hidden.insert(item.id)
        if items.indices.contains(index + 1) { index += 1 }
    }

    private func playCurrent() {
        guard active, items.indices.contains(index) else { return }
        let item = items[index]
        if isCovered(item) { players[item.id]?.pause(); return }
        let p = player(for: item)
        if !muted {
            PlayerModel.shared.player.pause()
            AppAudio.takeOver()
        }
        paused = false
        p.play()
        if fast { p.rate = 2 }
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

    /// True while you drag the progress bar, so the timer doesn't fight your finger.
    var scrubbing = false

    private func observeProgress(_ p: AVQueuePlayer) {
        if let obs = timeObserver { obs.0.removeTimeObserver(obs.1) }
        let token = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self, weak p] t in
            guard let d = p?.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
            let v = t.seconds / d
            Task { @MainActor in
                guard let self, !self.scrubbing else { return }
                self.progress = v; if self.duration != d { self.duration = d }
            }
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
    var onClose: (() -> Void)? = nil
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
                VerticalPager(count: shorts.items.count, index: $shorts.index, resetKey: shorts.source.rawValue) { i in
                    ShortPage(item: shorts.items[i], isCurrent: i == shorts.index)
                        .environmentObject(shorts).environmentObject(account).environmentObject(library)
                        .environmentObject(router).environmentObject(player)
                        .tint(Color.rumbleGreen)
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .overlay(alignment: .top) { topBar }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    /// TikTok-style top bar: Following | For You in the middle, sound on the right.
    private var topBar: some View {
        HStack {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                        .frame(width: 40, height: 40).background(.black.opacity(0.35), in: Circle())
                }
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
            Spacer()
            if onClose == nil && account.loggedIn {
                HStack(spacing: 18) {
                    ForEach([ShortsModel.Source.following, .all], id: \.self) { s in
                        Button { withAnimation(.easeInOut(duration: 0.15)) { shorts.switchSource(s) } } label: {
                            VStack(spacing: 4) {
                                Text(s.rawValue).font(.headline)
                                    .foregroundStyle(shorts.source == s ? .white : .white.opacity(0.6))
                                Capsule().fill(shorts.source == s ? Color.white : .clear).frame(width: 24, height: 3)
                            }
                        }
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 3)
            } else {
                Text(onClose == nil ? "Shorts" : "Following").font(.headline).shadow(color: .black.opacity(0.5), radius: 3)
            }
            Spacer()
            Button { shorts.toggleMute() } label: {
                Image(systemName: shorts.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.body).frame(width: 40, height: 40).background(.black.opacity(0.35), in: Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.top, 4)
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
    @ObservedObject private var mute = MuteUI.shared
    @State private var showComments = false
    @State private var showLogin = false
    @State private var toast: String?
    @State private var hearts: [Burst] = []
    @State private var captionOpen = false
    @State private var scrub: Double?

    struct Burst: Identifiable { let id = UUID(); let at: CGPoint; let tilt: Double }

    private var muteEntry: MutedEntry? { library.data.muteEntry(path: item.channel?.path, name: item.channel?.name) }
    private var covered: Bool { muteEntry != nil && !mute.revealed.contains(item.id) }

    var body: some View {
        ZStack {
            Color.black
            ShortSurface(player: shorts.player(for: item))
                .overlay { if covered { coverArt } }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { v in doubleTapLike(at: v.location) }
                        .exclusively(before: TapGesture().onEnded {
                            if captionOpen { withAnimation { captionOpen = false } } else { shorts.togglePause() }
                        })
                )
                .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 30) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    shorts.setFast(true)
                } onPressingChanged: { pressing in
                    if !pressing && shorts.fast { shorts.setFast(false) }
                }
            ForEach(hearts) { h in
                Image(systemName: "hand.thumbsup.fill")
                    .font(.system(size: 90)).foregroundStyle(Color.rumbleGreen)
                    .shadow(color: .black.opacity(0.4), radius: 6)
                    .rotationEffect(.degrees(h.tilt))
                    .position(h.at)
                    .transition(.asymmetric(insertion: .scale(scale: 0.4).combined(with: .opacity),
                                            removal: .scale(scale: 1.6).combined(with: .opacity)
                                                .combined(with: .offset(y: -80))))
                    .allowsHitTesting(false)
            }
            if isCurrent && shorts.paused && !covered && scrub == nil {
                Image(systemName: "play.fill").font(.system(size: 60)).foregroundStyle(.white.opacity(0.75))
                    .shadow(radius: 8).allowsHitTesting(false)
            }
            if isCurrent && shorts.fast {
                VStack {
                    Label("2× speed", systemImage: "forward.fill").font(.footnote.weight(.bold))
                        .padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white).padding(.top, 100)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            LinearGradient(colors: [.clear, .black.opacity(captionOpen ? 0.85 : 0.6)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            if let f = scrub {
                Text("\(TimeFormat.clock(f * shorts.duration)) / \(TimeFormat.clock(shorts.duration))")
                    .font(.system(size: 30, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .shadow(radius: 6).allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    info
                    Spacer(minLength: 8)
                    rail
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
                .opacity(scrub == nil ? 1 : 0)
                if isCurrent { scrubber }
            }
            .foregroundStyle(.white)
            if let t = toast {
                Text(t).font(.footnote.weight(.semibold)).padding(10).background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .clipped()
        .sheet(isPresented: $showComments) {
            NavigationStack {
                CommentsScreen(target: CommentTarget(video: item.asVideoItem, listID: item.commentListID,
                                                     videoNumericID: item.numericID, focusCommentID: nil))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showComments = false } } }
            }
            .environmentObject(account).environmentObject(player).environmentObject(library).environmentObject(router)
            .presentationDetents([.medium, .large])
            .muteSheetHost(active: true)
        }
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(account) }
        .onChange(of: covered) { c in if !c { shorts.reveal(item) } }
    }

    // MARK: muted cover

    private var coverArt: some View {
        ZStack {
            AsyncImage(url: item.thumbnail.flatMap(URL.init(string:))) { $0.image?.resizable().scaledToFill() }
                .blur(radius: 30).overlay(Color.black.opacity(0.45)).clipped()
            VStack(spacing: 12) {
                MuteBadge(tag: muteEntry?.tag).scaleEffect(1.3)
                Text("Content from a channel you muted").font(.subheadline).foregroundStyle(.white.opacity(0.85))
                Button("Show anyway") { shorts.reveal(item) }
                    .buttonStyle(.bordered).tint(.white)
            }
        }
    }

    // MARK: caption

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let c = item.channel, !covered {
                Button { router.open(c) } label: {
                    Text("@" + c.name).font(.subheadline.weight(.bold)).lineLimit(1)
                }
            }
            if !covered {
                Text(item.title).font(.subheadline)
                    .lineLimit(captionOpen ? 12 : 2)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { captionOpen.toggle() } }
                if !captionOpen && item.title.count > 70 {
                    Button("more") { withAnimation { captionOpen = true } }.font(.caption.weight(.semibold)).opacity(0.8)
                }
                if let v = item.views {
                    Label("\(CountFormat.short(v)) views", systemImage: "play.fill").font(.caption2).opacity(0.75)
                }
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
    }

    // MARK: right-hand rail

    private var rail: some View {
        VStack(spacing: 18) {
            if let c = item.channel { avatarFollow(c) }
            railButton(item.myVote == 1 ? "hand.thumbsup.fill" : "hand.thumbsup", CountFormat.short(item.likes),
                       tint: item.myVote == 1 ? Color.rumbleGreen : .white) { vote(1) }
            railButton(item.myVote == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown", CountFormat.short(item.dislikes),
                       tint: item.myVote == -1 ? .red : .white) { vote(-1) }
            railButton("ellipsis.bubble.fill", CountFormat.short(item.comments), tint: .white) { showComments = true }
            let saved = library.data.inWatchLater(item.id)
            railButton(saved ? "bookmark.fill" : "bookmark", saved ? "Saved" : "Save", tint: saved ? .yellow : .white) {
                library.data.toggleWatchLater(item.asVideoItem)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            if let url = URL(string: item.url) {
                ShareLink(item: url) {
                    VStack(spacing: 3) { Image(systemName: "arrowshape.turn.up.right.fill").font(.title); Text("Share").font(.caption2.weight(.semibold)) }
                }
            }
            Menu {
                Button { shorts.notInterested(item) } label: { Label("Not interested", systemImage: "hand.raised") }
                if let c = item.channel {
                    if let e = muteEntry {
                        Button(role: .destructive) { library.data.unmute(e.key) } label: { Label("Unmute channel", systemImage: "speaker.wave.2") }
                    } else {
                        Button { mute.muteChannel(c) } label: { Label("Mute channel…", systemImage: "speaker.slash") }
                    }
                }
                Button { player.play(item.asVideoItem) } label: { Label("Open in full player", systemImage: "rectangle.expand.vertical") }
            } label: {
                Image(systemName: "ellipsis").font(.title2).frame(width: 40, height: 30)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 3)
    }

    private func avatarFollow(_ c: ChannelRef) -> some View {
        let following = library.data.isFollowing(c.path)
        return ZStack(alignment: .bottom) {
            Button { router.open(c) } label: {
                ChannelAvatar(name: c.name, url: c.avatar, size: 46)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
            }
            if !following {
                Button {
                    library.data.toggleFollow(c)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Image(systemName: "plus").font(.caption.weight(.heavy)).foregroundStyle(.black)
                        .frame(width: 20, height: 20).background(Color.rumbleGreen, in: Circle())
                }
                .offset(y: 10)
            }
        }
        .padding(.bottom, 6)
    }

    private func railButton(_ icon: String, _ label: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title).foregroundStyle(tint)
                Text(label).font(.caption2.weight(.semibold))
            }
        }
    }

    // MARK: scrubber (drag to seek; grows while you drag)

    private var scrubber: some View {
        GeometryReader { g in
            let f = scrub ?? shorts.progress
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.25))
                Rectangle().fill(scrub == nil ? Color.white.opacity(0.85) : Color.rumbleGreen).frame(width: g.size.width * min(1, max(0, f)))
            }
            .frame(height: scrub == nil ? 2 : 6)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    shorts.scrubbing = true
                    scrub = min(1, max(0, v.location.x / g.size.width))
                }
                .onEnded { _ in
                    if let s = scrub { shorts.seek(to: s) }
                    shorts.scrubbing = false
                    withAnimation(.easeOut(duration: 0.15)) { scrub = nil }
                })
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.12), value: scrub == nil)
    }

    // MARK: likes

    private func doubleTapLike(at p: CGPoint) {
        guard !covered else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let b = Burst(at: p, tilt: Double.random(in: -18...18))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { hearts.append(b) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeIn(duration: 0.35)) { hearts.removeAll { $0.id == b.id } }
        }
        if item.myVote != 1 { vote(1) }   // double-tap only ever likes, like TikTok
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
    var resetKey: String = ""
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
        if context.coordinator.key != resetKey {
            context.coordinator.key = resetKey
            pvc.setViewControllers([context.coordinator.host(index)], direction: .forward, animated: false)
            return
        }
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
        var key: String
        init(_ parent: VerticalPager) { self.parent = parent; key = parent.resetKey }

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
