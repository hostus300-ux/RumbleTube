import SwiftUI

// MARK: - Model: gathers a candidate pool from Rumble pages and ranks it on the phone

@MainActor
final class DiscoverModel: ObservableObject {
    static let shared = DiscoverModel()

    enum Page: String, CaseIterable, Identifiable { case videos = "Videos", live = "Live"; var id: String { rawValue } }
    enum Sort: String, CaseIterable, Identifiable {
        case trending = "Trending", forYou = "For You", newest = "Newest"
        var id: String { rawValue }
        var icon: String {
            switch self { case .trending: return "flame"; case .forYou: return "sparkles"; case .newest: return "clock" }
        }
    }

    @Published private(set) var videos: [Sort: [RankedVideo]] = [:]
    @Published private(set) var live: [Sort: [RankedVideo]] = [:]
    @Published private(set) var loading = false
    @Published private(set) var forYouCold = false
    @Published var error: String?
    private var builtAt: Date?
    private var pool: [VideoItem] = []
    private var livePool: [VideoItem] = []
    private var chatRates: [String: Double] = [:]
    private var samplingChat = false

    func list(_ page: Page, _ sort: Sort) -> [RankedVideo] { (page == .videos ? videos : live)[sort] ?? [] }

    func refresh(force: Bool = false) async {
        if loading { return }
        if !force, let b = builtAt, Date().timeIntervalSince(b) < 15 * 60 { return }
        loading = true
        defer { loading = false }
        await gather()
        if pool.isEmpty && livePool.isEmpty { error = "Couldn't reach Rumble. Pull to try again."; return }
        error = nil
        rank()
        builtAt = Date()
        await buildForYou()
        Task { await sampleChat() }
    }

    // MARK: candidates

    private func gather() async {
        let svc = RumbleService.shared
        let home = HomeModel.shared
        if home.page == nil { await home.load() }
        var items: [VideoItem] = (home.page?.hero ?? []) + (home.page?.rows.flatMap(\.items) ?? [])
        // Every category row on the homepage, plus Editor Picks and the Live directory.
        var sources: [(path: String, category: String?)] = (home.page?.rows ?? []).compactMap { r in
            guard let p = r.feedPath, p.hasPrefix("/category/") || p.hasPrefix("/editor-picks") else { return nil }
            return (p, p.hasPrefix("/category/") ? r.title : nil)
        }
        if !sources.contains(where: { $0.path.hasPrefix("/editor-picks") }) { sources.append(("/editor-picks", nil)) }
        var liveItems: [VideoItem] = []
        await withTaskGroup(of: (Bool, [VideoItem]).self) { g in
            for s in sources.prefix(10) {
                g.addTask { @MainActor in
                    let page = try? await svc.listing(s.path, allowWebView: false)
                    return (false, (page?.items ?? []).map { var v = $0; if v.category == nil { v.category = s.category }; return v })
                }
            }
            for n in 1...2 {
                g.addTask { @MainActor in (true, (try? await svc.listing("/browse/live", page: n, allowWebView: false))?.items ?? []) }
            }
            for await (isLive, got) in g { if isLive { liveItems += got } else { items += got } }
        }
        // prefer the richer JSON copy of a video (has likes/comments) over a card copy
        var byID: [String: VideoItem] = [:]
        for v in items + liveItems where v.isShort != true {
            if let old = byID[v.id], old.likes != nil { continue }
            var v = v
            if v.category == nil { v.category = byID[v.id]?.category }
            byID[v.id] = v
        }
        let all = Array(byID.values)
        pool = all.filter { !$0.isLive }
        livePool = all.filter(\.isLive)
    }

    // MARK: ranking

    private func rank() {
        let snaps = SnapshotStore.load()
        let trending = TrendingRanker.videos(pool, previous: snaps)
        videos[.trending] = trending
        videos[.newest] = TrendingRanker.newest(pool, live: false)
        live[.trending] = TrendingRanker.live(livePool, chatPerMinute: chatRates)
        live[.newest] = TrendingRanker.newest(livePool, live: true)
        SnapshotStore.update(snaps, with: pool)
    }

    private func buildForYou() async {
        let lib = LibraryStore.shared.data
        var follows = lib.follows
        if AccountStore.shared.loggedIn, let rumble = try? await RumbleService.shared.followedChannels() {
            follows += rumble.map(\.ref)
        }
        let history = lib.history.map { (video: $0.video, at: $0.watchedAt) }
        let profile = TasteProfile.build(history: history, completion: { lib.watchFraction(for: $0) }, follows: follows)
        forYouCold = profile.isCold
        var candidates = pool
        // Latest from channels you like most, and this week's results for your top topics.
        let svc = RumbleService.shared
        await withTaskGroup(of: [VideoItem].self) { g in
            for path in profile.topChannels.prefix(4) {
                g.addTask { @MainActor in (try? await svc.channel(path))?.items ?? [] }
            }
            for word in profile.topKeywords.prefix(2) {
                g.addTask { @MainActor in (try? await svc.search(word, sort: .date))?.items ?? [] }
            }
            for await got in g { candidates += got }
        }
        let trendScores = Dictionary((videos[.trending] ?? []).map { ($0.id, $0.score) }, uniquingKeysWith: { a, _ in a })
        let watched: (VideoItem) -> Double? = { lib.watchFraction(for: $0) }
        videos[.forYou] = profile.isCold ? (videos[.trending] ?? [])
            : ForYouRanker.rank(candidates, profile: profile, live: false, trending: trendScores, watchedFraction: watched)
        let liveFY = ForYouRanker.rank(livePool, profile: profile, live: true)
        live[.forYou] = profile.isCold || liveFY.isEmpty ? (live[.trending] ?? []) : liveFY
    }

    // MARK: chat speed for the top live streams

    private func sampleChat() async {
        guard !samplingChat else { return }
        samplingChat = true
        defer { samplingChat = false }
        let top = (live[.trending] ?? []).prefix(10).map(\.item)
        var rates: [String: Double] = [:]
        await withTaskGroup(of: (String, Double?).self) { g in
            for v in top {
                g.addTask { @MainActor in
                    guard let d = try? await RumbleService.shared.detail(for: v), let c = d.chat else { return (v.id, nil) }
                    return (v.id, await ChatSampler.messagesPerMinute(c, seconds: 15))
                }
            }
            for await (id, r) in g { if let r { rates[id] = r } }
        }
        guard !rates.isEmpty else { return }
        chatRates.merge(rates) { _, new in new }
        live[.trending] = TrendingRanker.live(livePool, chatPerMinute: chatRates)
    }
}

/// Counts new chat messages on a live stream for a few seconds.
enum ChatSampler {
    static func messagesPerMinute(_ c: ChatConfig, seconds: Double) async -> Double? {
        var req = URLRequest(url: LiveChatParser.streamURL(c))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = seconds + 5
        let task = Task<Int?, Never> {
            guard let res = try? await RumbleHTTP.session.bytes(for: req),
                  (res.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let bytes = res.0
            var count = 0
            do {
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data:"),
                          let e = LiveChatParser.parseEvent(Data(line.dropFirst(5).utf8)), e.type != "init" else { continue }
                    count += e.messages.count
                }
            } catch {}
            return count
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        task.cancel()
        guard let n = await task.value else { return nil }
        return Double(n) * 60 / seconds
    }
}

/// View counts remembered between visits, so Trending can measure real views/hour.
enum SnapshotStore {
    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("view-snapshots.json")
    }
    static func load() -> [String: ViewSnapshot] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: ViewSnapshot].self, from: $0) } ?? [:]
    }
    /// Keep a baseline at least ~6 h old so the next visit has a useful gap; drop entries over 8 days.
    static func update(_ old: [String: ViewSnapshot], with items: [VideoItem], now: Date = Date()) {
        var s = old.filter { now.timeIntervalSince($0.value.at) < 8 * 86_400 }
        for v in items {
            guard let views = v.viewCount else { continue }
            if let e = s[v.id], now.timeIntervalSince(e.at) < 6 * 3600 { continue }
            s[v.id] = ViewSnapshot(views: views, at: now)
        }
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - Screen

struct DiscoverScreen: View {
    @ObservedObject private var model = DiscoverModel.shared
    @EnvironmentObject var player: PlayerModel
    @State private var page = DiscoverModel.Page(rawValue: LibraryStore.shared.data.prefs.discoverPage) ?? .videos
    @State private var videoSort = DiscoverModel.Sort(rawValue: LibraryStore.shared.data.prefs.discoverSort) ?? .trending
    @State private var liveSort = DiscoverModel.Sort(rawValue: LibraryStore.shared.data.prefs.discoverSort) ?? .trending

    var body: some View {
        // The pages fill the screen and scroll underneath the glass header (title + Videos / Live).
        TabView(selection: $page) {
            feed(.videos, sort: $videoSort).tag(DiscoverModel.Page.videos)
            feed(.live, sort: $liveSort).tag(DiscoverModel.Page.live)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeInOut(duration: 0.2), value: page)
        .appHeader("Discover") {
            Picker("Show", selection: $page) {
                ForEach(DiscoverModel.Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .task { await model.refresh() }
    }

    private func feed(_ p: DiscoverModel.Page, sort: Binding<DiscoverModel.Sort>) -> some View {
        let list = model.list(p, sort.wrappedValue)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DiscoverModel.Sort.allCases) { s in
                            Button { withAnimation(.easeInOut(duration: 0.15)) { sort.wrappedValue = s } } label: {
                                Chip(title: s.rawValue, icon: s.icon, selected: sort.wrappedValue == s)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                if sort.wrappedValue == .forYou && model.forYouCold {
                    Text("Watch a few videos and For You will start matching your taste. Showing Trending for now.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
                }
                CardGrid {
                    ForEach(list) { r in
                        Button { player.play(r.item) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                if let reason = r.reason {
                                    Text(reason).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 12)
                                }
                                VideoCard(item: r.item)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if list.isEmpty {
                    VStack(spacing: 10) {
                        if model.loading { ProgressView() }
                        else if let e = model.error {
                            Text(e).font(.footnote).foregroundStyle(.secondary)
                            Button("Try again") { Task { await model.refresh(force: true) } }.buttonStyle(.bordered)
                        } else {
                            Text(p == .live ? "No live streams right now." : "Nothing here yet.").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(50)
                }
            }
        }
        .reportsScrollToHeader()
        .refreshable { await model.refresh(force: true) }
        .miniPlayerSpace()
    }
}
