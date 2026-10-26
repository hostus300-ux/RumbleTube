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

    private var running: Task<Void, Never>?

    /// Runs on its own task: switching chips or pages no longer cancels a half-finished load
    /// (which used to leave Discover empty until the next 15-minute refresh).
    func refresh(force: Bool = false) async {
        if let r = running { await r.value; return }
        let t = Task { @MainActor in await self.build(force: force) }
        running = t
        await t.value
        running = nil
    }

    private func build(force: Bool) async {
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

// MARK: - Sections

/// What the chips under Discover's Videos / Live switch show.
enum DiscoverSection: String, CaseIterable, Identifiable {
    case trending = "Trending", popular = "Popular", forYou = "For You", editorPicks = "Editor Picks"
    case latest = "Latest", browse = "Browse", featured = "Featured", newest = "Newest"
    var id: String { rawValue }

    static let videoSections: [DiscoverSection] = [.trending, .popular, .forYou, .editorPicks, .latest]
    /// Browse (categories) and Featured channels are mostly about live streams, so they live on the Live page.
    static let liveSections: [DiscoverSection] = [.trending, .popular, .forYou, .editorPicks, .latest, .browse, .featured]

    var icon: String {
        switch self {
        case .trending: return "chart.line.uptrend.xyaxis"
        case .popular: return "flame"
        case .forYou: return "sparkles"
        case .editorPicks: return "star"
        case .latest, .newest: return "clock"
        case .browse: return "square.grid.2x2"
        case .featured: return "person.2"
        }
    }

    /// Sections ranked on the phone (the rest come straight from rumble.com).
    var ranked: DiscoverModel.Sort? {
        switch self {
        case .popular: return .trending
        case .forYou: return .forYou
        case .newest: return .newest
        default: return nil
        }
    }

    /// Older versions stored "Trending" for the phone-ranked list; it's still a valid choice (now rumble.com's own).
    static func fromPref(_ s: String, live: Bool) -> DiscoverSection {
        let v = DiscoverSection(rawValue: s) ?? .trending
        let allowed = live ? liveSections : videoSections
        return allowed.contains(v) ? v : allowed[0]
    }
}

/// rumble.com's own lists (Trending, Editor Picks, Latest), Browse and Featured channels.
@MainActor
final class DiscoverSiteFeeds: ObservableObject {
    static let shared = DiscoverSiteFeeds()
    let trending = ListingModel { try await RumbleService.shared.trending(page: $0) }
    let editorPicks = ListingModel { try await RumbleService.shared.listing("/editor-picks", page: $0, allowWebView: false) }
    let latest = ListingModel { try await RumbleService.shared.latest(page: $0) }
    @Published private(set) var categories: [BrowseCategory] = []
    @Published private(set) var featured: [FeaturedChannel] = []
    @Published private(set) var loading = false
    @Published var error: String?

    func listing(_ s: DiscoverSection) -> ListingModel? {
        switch s {
        case .trending: return trending
        case .editorPicks: return editorPicks
        case .latest: return latest
        default: return nil
        }
    }

    func loadBrowse(force: Bool = false) async {
        guard force || categories.isEmpty, !loading else { return }
        loading = true
        // Own task, so leaving the page mid-load doesn't cancel it.
        let r = await Task { @MainActor in try await RumbleService.shared.browse() }.result
        loading = false
        switch r {
        case .success(let c): categories = c; error = nil
        case .failure: if categories.isEmpty { error = "Couldn't load categories. Pull to try again." }
        }
    }

    func loadFeatured(force: Bool = false) async {
        guard force || featured.isEmpty, !loading else { return }
        loading = true
        let r = await Task { @MainActor in try await RumbleService.shared.featuredChannels() }.result
        loading = false
        switch r {
        case .success(let f): featured = f; error = nil
        case .failure: if featured.isEmpty { error = "Couldn't load featured channels. Pull to try again." }
        }
    }
}

// MARK: - Screen

struct DiscoverScreen: View {
    @ObservedObject private var model = DiscoverModel.shared
    @EnvironmentObject var player: PlayerModel
    @State private var page = DiscoverModel.Page(rawValue: LibraryStore.shared.data.prefs.discoverPage) ?? .videos
    @State private var videoSection = DiscoverSection.fromPref(LibraryStore.shared.data.prefs.discoverSort, live: false)
    @State private var liveSection = DiscoverSection.fromPref(LibraryStore.shared.data.prefs.discoverSort, live: true)

    var body: some View {
        // The pages fill the screen and scroll underneath the header (title + Videos / Live).
        TabView(selection: $page) {
            DiscoverFeed(page: .videos, section: $videoSection).tag(DiscoverModel.Page.videos)
            DiscoverFeed(page: .live, section: $liveSection).tag(DiscoverModel.Page.live)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeInOut(duration: 0.2), value: page)
        .appHeader("Discover", chips: {
            VStack(spacing: 8) {
                Picker("Show", selection: $page) {
                    ForEach(DiscoverModel.Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                // Section chips live in the header so they hide and come back with it.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(page == .live ? DiscoverSection.liveSections : DiscoverSection.videoSections) { s in
                            let sel = page == .live ? liveSection : videoSection
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if page == .live { liveSection = s } else { videoSection = s }
                                }
                            } label: { Chip(title: s.rawValue, icon: s.icon, selected: sel == s) }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        })
    }
}

/// One Discover page (Videos or Live): section chips, then that section's content.
private struct DiscoverFeed: View {
    let page: DiscoverModel.Page
    @Binding var section: DiscoverSection
    @ObservedObject private var model = DiscoverModel.shared
    @ObservedObject private var site = DiscoverSiteFeeds.shared
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var router: Router

    private var sections: [DiscoverSection] { page == .live ? DiscoverSection.liveSections : DiscoverSection.videoSections }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.top, 8)
        }
        .reportsScrollToHeader()
        .pullToRefresh { await refresh(force: true) }
        .task(id: section) { await refresh(force: false) }
        .miniPlayerSpace()
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sections) { s in
                    Button { withAnimation(.easeInOut(duration: 0.15)) { section = s } } label: {
                        Chip(title: s.rawValue, icon: s.icon, selected: section == s)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    @ViewBuilder private var content: some View {
        if let sort = section.ranked {
            rankedList(model.list(page, sort))
        } else if let feed = site.listing(section) {
            // rumble.com's lists mix uploads and streams: each page shows only its own kind.
            SiteListing(model: feed, live: page == .live)
        } else if section == .browse {
            browseGrid
        } else if section == .featured {
            featuredList
        }
    }

    private func refresh(force: Bool) async {
        if section.ranked != nil { await model.refresh(force: force) }
        else if let feed = site.listing(section) {
            if force || !feed.loadedOnce { await feed.reload() }
        } else if section == .browse { await site.loadBrowse(force: force) }
        else if section == .featured { await site.loadFeatured(force: force) }
    }

    // MARK: phone-ranked (Popular / For You / Newest)

    @ViewBuilder private func rankedList(_ list: [RankedVideo]) -> some View {
        if section == .forYou && model.forYouCold {
            Text("Watch a few videos and For You will start matching your taste. Showing Popular for now.")
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
            emptyState(loading: model.loading, error: model.error,
                       empty: page == .live ? "No live streams right now." : "Nothing here yet.") {
                Task { await model.refresh(force: true) }
            }
        }
    }

    // MARK: Browse

    private var browseGrid: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 14) {
                ForEach(site.categories) { c in
                    NavigationLink(value: AppRoute.listing(title: c.title, path: c.path)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Color.secondary.opacity(0.15)
                                .aspectRatio(2 / 3, contentMode: .fit)
                                .overlay {
                                    if let s = c.image, let u = URL(string: s) {
                                        AsyncImage(url: u) { $0.image?.resizable().scaledToFill() }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(c.title).font(.caption.weight(.semibold)).lineLimit(1)
                            if let v = c.viewers {
                                Text(v).font(.caption2).foregroundStyle(Color.rumbleRed).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            if site.categories.isEmpty {
                emptyState(loading: site.loading, error: site.error, empty: "No categories.") { Task { await site.loadBrowse(force: true) } }
            }
        }
    }

    // MARK: Featured channels

    private var featuredList: some View {
        LazyVStack(spacing: 0) {
            ForEach(site.featured) { f in
                Button { open(f) } label: {
                    HStack(spacing: 12) {
                        ChannelAvatar(name: f.name, url: f.avatar, size: 44)
                            .overlay(Circle().stroke(f.livePath != nil ? Color.rumbleRed : .clear, lineWidth: 2.5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if f.livePath != nil {
                                Text(f.viewers.map { "● LIVE · \($0) watching" } ?? "● LIVE")
                                    .font(.caption.weight(.semibold)).foregroundStyle(Color.rumbleRed)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if site.featured.isEmpty {
                emptyState(loading: site.loading, error: site.error, empty: "No featured channels.") { Task { await site.loadFeatured(force: true) } }
            }
        }
    }

    private func open(_ f: FeaturedChannel) {
        if let live = f.livePath, let item = RumbleService.item(fromLink: "https://rumble.com" + live) {
            player.play(item)
        } else if let ref = f.ref {
            router.open(ref)
        }
    }

    private func emptyState(loading: Bool, error: String?, empty: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            if loading { ProgressView() }
            else if let e = error {
                Text(e).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again", action: retry).buttonStyle(.bordered)
            } else {
                Text(empty).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(50)
    }
}

/// A rumble.com list (Trending, Editor Picks, Latest) with paging as you reach the end.
private struct SiteListing: View {
    @ObservedObject var model: ListingModel
    /// true: only live streams; false: only uploads (no live or upcoming).
    let live: Bool
    @EnvironmentObject var player: PlayerModel

    private var shown: [VideoItem] {
        model.items.filter { live ? $0.isLive : (!$0.isLive && $0.upcoming != true) }
    }

    var body: some View {
        let items = shown
        CardGrid {
            ForEach(items) { v in
                Button { player.play(v) } label: { VideoCard(item: v) }
                    .buttonStyle(.plain)
                    .onAppear { if v.id == items.last?.id { Task { await model.loadMore() } } }
            }
        }
        // Few matches on the pages loaded so far (e.g. streams in Latest): fetch more pages, within reason.
        .task(id: model.items.count) {
            if items.count < 8, model.hasNext, model.loadedOnce, !model.loading, model.items.count < 240 {
                await model.loadMore()
            }
        }
        if items.isEmpty {
            VStack(spacing: 10) {
                if let e = model.error, !model.loading {
                    Text(e).font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { Task { await model.reload() } }.buttonStyle(.bordered)
                } else if model.loading || !model.loadedOnce || (model.hasNext && model.items.count < 240) {
                    ProgressView()
                } else {
                    Text("Nothing here right now.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity).padding(50)
        } else if model.loading {
            ProgressView().frame(maxWidth: .infinity).padding()
        }
    }
}
