import SwiftUI

// MARK: - Navigation routes & shared chrome

enum AppRoute: Hashable {
    case search, inbox, settings, appSettings, followingList, earnings, history, watchLater, followedShorts, create, downloads
    case listing(title: String, path: String)
}

extension AppRoute {
    @ViewBuilder var screen: some View {
        switch self {
        case .search: SearchScreen()
        case .create: CreateScreen()
        case .downloads: DownloadsScreen()
        case .inbox: InboxView()
        case .settings: RumbleSettingsScreen()
        case .appSettings: SettingsView()
        case .followingList: FollowingListScreen()
        case .earnings: EarningsScreen()
        case .history: HistoryScreen()
        case .watchLater: WatchLaterScreen()
        case .followedShorts: FollowedShortsScreen()
        case .listing(let title, let path): ListingScreen(title: title, path: path)
        }
    }
}

/// Search + notification bell in the top-right of every main screen (plus Settings on Account).
struct AppToolbar: ViewModifier {
    var settings = false
    @EnvironmentObject var account: AccountStore

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                NavigationLink(value: AppRoute.search) { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search")
                NavigationLink(value: AppRoute.inbox) {
                    Image(systemName: account.hasUnread ? "bell.badge" : "bell")
                        .symbolRenderingMode(account.hasUnread ? .multicolor : .monochrome)
                }
                .accessibilityLabel("Notifications")
                if settings {
                    NavigationLink(value: AppRoute.settings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
        }
    }
}

/// Keeps the bottom of every screen clear of the mini player.
struct MiniPlayerSpace: ViewModifier {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var library: LibraryStore
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            // In the tab-bar accessory the system already makes room for the player.
            if player.item != nil && !GlassUI.usesAccessory {
                Color.clear.frame(height: GlassUI.available && library.data.prefs.liquidGlass ? 78 : 66)
            }
        }
    }
}

extension View {
    func appToolbar(settings: Bool = false) -> some View { modifier(AppToolbar(settings: settings)) }
    func miniPlayerSpace() -> some View { modifier(MiniPlayerSpace()) }
}

enum ContentFilter: String, CaseIterable, Identifiable {
    case all = "All", videos = "Videos", live = "Live"
    var id: String { rawValue }
    func keep(_ v: VideoItem) -> Bool {
        switch self {
        case .all: return true
        case .videos: return !v.isLive && v.upcoming != true
        case .live: return v.isLive || v.upcoming == true
        }
    }
}

/// Filter chip in the YouTube app's style: a soft rounded rectangle, filled light when selected.
/// Live chips use rumble.com's red.
struct Chip: View {
    let title: String
    var icon: String? = nil
    var asset: String? = nil
    var selected = false
    /// Optional tag colour (channel tags in My Feed).
    var tint: Color? = nil
    @Environment(\.colorScheme) private var scheme
    private var isLive: Bool { title.caseInsensitiveCompare("Live") == .orderedSame }

    private var fill: Color {
        if isLive { return Color.rumbleRed.opacity(selected ? 1 : 0.8) }
        if let tint { return selected ? tint : tint.opacity(0.22) }
        if selected { return scheme == .dark ? .white : .black }
        return scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05)
    }
    private var ink: Color {
        if isLive { return .white }
        if tint != nil { return selected ? .white : .primary }
        if selected { return scheme == .dark ? .black : .white }
        return .primary
    }

    var body: some View {
        HStack(spacing: 5) {
            if let asset { Image(asset).renderingMode(.template).resizable().scaledToFit().frame(width: 14, height: 14) }
            else if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
            Text(title).font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isLive && selected { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.85), lineWidth: 1.5) }
        }
        .foregroundStyle(ink)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}

private struct ChipGlass: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on && GlassUI.enabled { content.glassCapsule() } else { content }
    }
}

struct FilterChips: View {
    @Binding var filter: ContentFilter
    var body: some View {
        HStack(spacing: 8) {
            ForEach(ContentFilter.allCases) { f in
                Button { withAnimation(.easeInOut(duration: 0.15)) { filter = f } } label: { Chip(title: f.rawValue, selected: filter == f) }
                    .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Home (Rumble's homepage rows)

@MainActor
final class HomeModel: ObservableObject {
    static let shared = HomeModel()
    @Published var page: HomePage?
    @Published var loading = false
    @Published var error: String?
    @Published private(set) var fetchedAt: Date?

    /// Show the last saved Home instantly (stale-while-revalidate). Returns true if a usable cache existed.
    @discardableResult
    func loadCache(maxAge: TimeInterval = 86_400) -> Bool {
        guard page == nil, let c = HomeCache.load(maxAge: maxAge) else { return page != nil }
        page = c
        return true
    }

    /// Videos for category rows (the homepage rows only carry their live streams).
    @Published var videoRows: [String: [VideoItem]] = [:]

    func loadVideoRows() async {
        guard let rows = page?.rows else { return }
        await withTaskGroup(of: (String, [VideoItem]).self) { g in
            for r in rows where videoRows[r.id] == nil {
                guard let p = r.feedPath, p.split(separator: "/").count == 2, p.hasPrefix("/category/") else { continue }
                g.addTask { @MainActor in
                    let items = (try? await RumbleService.shared.listing(p + "/videos", allowWebView: false))?.items ?? []
                    return (r.id, items.filter { $0.isShort != true }.map { var v = $0; v.category = r.title; return v })
                }
            }
            for await (id, items) in g { videoRows[id] = items }
        }
    }

    private var running: Task<Void, Never>?

    /// Reload Home. A pull-to-refresh during a load waits for that load instead of returning at once.
    func load() async {
        if let r = running { await r.value; return }
        let t = Task { @MainActor in
            loading = true
            defer { loading = false }
            do {
                let fresh = try await RumbleService.shared.home()
                page = fresh; error = nil; fetchedAt = Date(); videoRows = [:]
                HomeCache.save(fresh)
            }
            catch { if page == nil { self.error = error.localizedDescription } }
        }
        running = t
        await t.value
        running = nil
    }
}

/// Last good homepage, saved in Caches so a cold start can show it immediately.
/// Followed channels from last time, so My Feed's circles appear instantly.
enum FollowedChannelCache {
    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("followed-channels.json")
    }
    static func save(_ c: [FollowedChannel]) {
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: url, options: .atomic) }
    }
    static func load() -> [FollowedChannel] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([FollowedChannel].self, from: $0) } ?? []
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}

enum HomeCache {
    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("home-page.json")
    }
    static func save(_ p: HomePage) {
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: url, options: .atomic) }
    }
    static func load(maxAge: TimeInterval) -> HomePage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mod = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mod) < maxAge,
              let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HomePage.self, from: d)
    }
}

struct HomeScreen: View {
    @ObservedObject private var model = HomeModel.shared
    @EnvironmentObject var player: PlayerModel
    @State private var filter: ContentFilter = ContentFilter(rawValue: LibraryStore.shared.data.prefs.homeFilter) ?? .all

    /// All / Videos / Live, then Rumble's sections. Part of the header, so they hide and return with it.
    private var homeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChips(filter: $filter)
                if let pills = model.page?.pills, !pills.isEmpty {
                    Divider().frame(height: 22)
                    // Rumble's own "Live" pill duplicates the Live filter, so it's left out.
                    ForEach(pills.filter { $0.title.caseInsensitiveCompare("Live") != .orderedSame }) { p in
                        if let row = model.page?.rows.first(where: { $0.id == p.id }), let path = row.feedPath {
                            NavigationLink(value: AppRoute.listing(title: p.title, path: path)) { Chip(title: p.title) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let hero = model.page?.hero.filter(filter.keep).first {
                    Button { player.play(hero) } label: { VideoCard(item: hero) }.buttonStyle(.plain)
                }
                ForEach(model.page?.rows ?? []) { row in
                    let items = row.items.filter(filter.keep)
                    if !items.isEmpty { HomeRowView(row: row, items: items) }
                    else if filter == .videos, let v = model.videoRows[row.id], !v.isEmpty { HomeRowView(row: row, items: v) }
                }
                if model.loading && model.page == nil { ProgressView().frame(maxWidth: .infinity).padding(60) }
                if let e = model.error {
                    VStack(spacing: 10) {
                        Text(e).font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { Task { await model.load() } }.buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.bottom, 20)
        }
        .reportsScrollToHeader()
        .pullToRefresh {
            await model.load()
            if filter == .videos { await model.loadVideoRows() }
        }
        .task(id: filter) { if filter == .videos { await model.loadVideoRows() } }
        .task { if model.fetchedAt == nil && !model.loading { await model.load() } }
        .appHeader("Home", chips: { homeChips })
        .miniPlayerSpace()
    }
}

struct HomeRowView: View {
    let row: HomeRow
    let items: [VideoItem]
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(row.title).font(.title3.weight(.bold))
                Spacer()
                if let path = row.feedPath {
                    NavigationLink(value: AppRoute.listing(title: row.title, path: path)) {
                        Text("See all").font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        Button { player.play(item) } label: { CompactCard(item: item) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }
}

/// Card for horizontal rows.
struct CompactCard: View {
    let item: VideoItem
    var width: CGFloat = 260
    @EnvironmentObject var library: LibraryStore

    var body: some View { MuteGate(item: item, compactWidth: width) { card } }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumbnail(item: item, progress: progress, tags: library.data.tags(for: item.channelPath))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                ChannelAvatar(name: item.channelName ?? "?", url: item.channelAvatar, size: 20, path: item.channelPath)
                Text(item.channelName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(metaLine(item)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .videoContextMenu(item)
    }

    private var progress: Double? { library.data.watchFraction(for: item) }
}

// MARK: - Any listing page ("See all", categories, Live…)

/// A "See all" page. Rumble splits categories: /category/x holds the live streams and /category/x/videos the
/// videos, so each filter loads the right page instead of filtering one list (which left Videos empty).
struct ListingScreen: View {
    let title: String
    let path: String
    @State private var filter: ContentFilter = .all
    @StateObject private var mixed: ListingModel

    private enum Kind { case category, liveOnly, mixed }
    private var kind: Kind {
        let parts = path.split(separator: "/")
        if parts.count == 2, parts[0] == "category" { return .category }
        if path.hasPrefix("/browse/live") { return .liveOnly }
        return .mixed
    }

    init(title: String, path: String) {
        self.title = title
        self.path = path
        _mixed = StateObject(wrappedValue: ListingModel { page in try await RumbleService.shared.listing(path, page: page) })
    }

    var body: some View {
        Group {
            switch kind {
            case .category:
                ListingView(model: categoryModel(filter), filter: .all) { chips }
                    .id(filter)
            case .liveOnly:
                ListingView(model: mixed, filter: .all)
            case .mixed:
                // Only offer All / Videos / Live when the page really has both.
                let hasBoth = mixed.items.contains(where: \.isLive) && mixed.items.contains(where: { !$0.isLive })
                ListingView(model: mixed, filter: hasBoth ? filter : .all) { if hasBoth { chips } }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .appToolbar()
        .miniPlayerSpace()
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) { FilterChips(filter: $filter).padding(.horizontal, 12) }
            .padding(.vertical, 8)
    }

    private func categoryModel(_ f: ContentFilter) -> ListingModel {
        let base = path
        let svc = RumbleService.shared
        switch f {
        case .live:
            return ListingModel { page in try await svc.listing(base, page: page) }
        case .videos:
            return ListingModel { page in try await svc.listing(base + "/videos", page: page) }
        case .all:
            // Live streams on top, then the category's videos (which keep paging).
            return ListingModel { page in
                var videos = try await svc.listing(base + "/videos", page: page)
                if page == 1, let live = try? await svc.listing(base) { videos.items = live.items.filter(\.isLive) + videos.items }
                return videos
            }
        }
    }
}

// MARK: - Search

struct SearchScreen: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var router: Router
    @EnvironmentObject var library: LibraryStore
    @State private var text = ""
    @State private var submitted = ""
    @State private var sort: SearchSort = .relevance
    @State private var filter: ContentFilter = .all
    @State private var channelsOnly = false
    @State private var channels: [ChannelResult] = []
    @State private var channelsLoading = false

    var body: some View {
        VStack(spacing: 0) {
            if let link = RumbleService.item(fromLink: text) {
                Button { player.play(link) } label: {
                    Label("Open this Rumble link", systemImage: "link").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.rumbleGreen).foregroundStyle(.black).padding()
            } else if let path = RumbleURL.channelPath(from: text), text.contains("rumble.com") {
                Button { router.open(ChannelRef(path: path, name: String(path.split(separator: "/").last ?? ""))) } label: {
                    Label("Open this channel", systemImage: "person.crop.square").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.rumbleGreen).foregroundStyle(.black).padding()
            }
            if submitted.isEmpty || (!text.isEmpty && text != submitted && !suggestions.isEmpty) {
                suggestionList
            } else if channelsOnly {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        chips
                        if channelsLoading && channels.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(40) }
                        if !channelsLoading && channels.isEmpty {
                            Text("No channels found.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                        }
                        ForEach(channels) { c in
                            Button { router.open(c.ref) } label: { channelRow(c) }.buttonStyle(.plain)
                        }
                    }
                }
            } else {
                let q = submitted, s = sort
                ListingView(model: ListingModel { page in try await RumbleService.shared.search(q, sort: s, page: page) },
                            filter: filter) {
                    VStack(alignment: .leading, spacing: 0) {
                        chips
                        if !channels.isEmpty && filter == .all {
                            HStack {
                                Text("Channels").font(.headline)
                                Spacer()
                                if channels.count > 3 {
                                    Button("See all") { channelsOnly = true }.font(.subheadline.weight(.semibold))
                                }
                            }
                            .padding(.horizontal, 12).padding(.top, 4)
                            ForEach(channels.prefix(3)) { c in
                                Button { router.open(c.ref) } label: { channelRow(c) }.buttonStyle(.plain)
                            }
                            Divider().padding(.vertical, 8)
                        }
                    }
                }
                .id("\(q)|\(s.rawValue)")
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Rumble or paste a link")
        .onSubmit(of: .search) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let link = RumbleService.item(fromLink: t) { player.play(link) } else if !t.isEmpty { run(t) }
        }
        .task(id: submitted) {
            guard !submitted.isEmpty else { return }
            channels = []
            channelsLoading = true
            channels = (try? await RumbleService.shared.searchChannels(submitted)) ?? []
            channelsLoading = false
        }
        .miniPlayerSpace()
    }

    private func run(_ q: String) {
        text = q
        submitted = q
        library.data.addSearch(q)
    }

    private var suggestions: [SearchSuggest.Item] {
        let chans = library.data.follows + MyFeedModel.shared.channels.map(\.ref)
        return SearchSuggest.items(for: text, history: library.data.searchHistory, channels: chans)
    }

    @ViewBuilder private var suggestionList: some View {
        let items = suggestions
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Search Rumble, or paste a rumble.com link.").foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(items, id: \.self) { it in
                        switch it {
                        case .recent(let q):
                            Button { run(q) } label: {
                                HStack {
                                    Label(q, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.left").foregroundStyle(.secondary).font(.caption)
                                }
                            }
                            .swipeActions { Button("Delete", role: .destructive) { library.data.searchHistory.removeAll { $0 == q } } }
                        case .channel(let c):
                            Button { router.open(c) } label: {
                                HStack(spacing: 10) {
                                    ChannelAvatar(name: c.name, url: c.avatar, size: 28, path: c.path)
                                    Text(c.name).foregroundStyle(.primary)
                                    Spacer()
                                    Text("Channel").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    if text.isEmpty {
                        HStack {
                            Text("Recent searches")
                            Spacer()
                            Button("Clear") { library.data.searchHistory = [] }.font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ContentFilter.allCases) { f in
                    Button { channelsOnly = false; filter = f } label: { Chip(title: f.rawValue, selected: !channelsOnly && filter == f) }
                        .buttonStyle(.plain)
                }
                Button { channelsOnly = true } label: { Chip(title: "Channels", icon: "person.crop.circle", selected: channelsOnly) }
                    .buttonStyle(.plain)
                if !channelsOnly {
                    Divider().frame(height: 22)
                    Menu {
                        Picker("Sort", selection: $sort) { ForEach(SearchSort.allCases) { Text($0.rawValue).tag($0) } }
                    } label: { Chip(title: sort.rawValue, icon: "arrow.up.arrow.down") }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
    }

    private func channelRow(_ c: ChannelResult) -> some View {
        HStack(spacing: 12) {
            ChannelAvatar(name: c.ref.name, url: c.ref.avatar, size: 48, path: c.ref.path)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(c.ref.name).font(.body.weight(.semibold)).lineLimit(1)
                    if c.verified { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Color.rumbleGreen) }
                }
                if let f = c.followers { Text("\(f) followers").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - My Feed

@MainActor
final class MyFeedModel: ObservableObject {
    static let shared = MyFeedModel()
    @Published var channels: [FollowedChannel] = FollowedChannelCache.load()
    @Published var liveByChannel: [String: VideoItem] = [:]
    @Published var items: [VideoItem] = []
    @Published var pill: MyFeedPill = MyFeedPill(rawValue: LibraryStore.shared.data.prefs.myFeedPill) ?? .all
    @Published var loading = false
    @Published var error: String?
    @Published var hasMore = false
    private var offset = 0
    private var channelsAt: Date?
    private var feedKey: String?

    /// Circles first (they come from a small, fast request), then live rings and the feed fill in as each arrives.
    func load(signedIn: Bool, localFollows: [ChannelRef], force: Bool = false) async {
        if signedIn {
            async let c: Void = refreshChannels(force: force)
            async let l: Void = refreshLive(force: force)
            async let f: Void = loadFeed(force: force)
            _ = await (c, l, f)
        } else {
            loading = true
            defer { loading = false }
            offset = 0
            channels = localFollows.map { FollowedChannel(ref: $0, lastActivity: nil, liveViewers: nil, followers: nil) }
            let r = await RumbleService.shared.feed(localFollows)
            items = r.items
            liveByChannel = Dictionary(r.items.filter(\.isLive).compactMap { v in v.channelPath.map { ($0.lowercased(), v) } },
                                       uniquingKeysWith: { a, _ in a })
            hasMore = false
            error = r.failed.isEmpty ? nil : "Couldn't load: \(r.failed.map(\.name).joined(separator: ", "))"
        }
    }

    /// Followed channels for the circles. Shown from the saved copy instantly; refreshed at most every 2 minutes.
    func refreshChannels(force: Bool = false) async {
        if !force, let t = channelsAt, Date().timeIntervalSince(t) < 120 { return }
        guard let c = try? await RumbleService.shared.followedChannels() else { return }
        channels = c
        channelsAt = Date()
        FollowedChannelCache.save(c)
        AvatarCache.shared.prefetch(c.prefix(20).compactMap(\.ref.avatar))
        WidgetBridge.update()
    }

    private func refreshLive(force: Bool) async {
        guard let l = try? await RumbleService.shared.followingFeed(pill: "live", offset: 0, limit: 30) else { return }
        var map: [String: VideoItem] = [:]
        for v in l.items where v.isLive { if let p = v.channelPath?.lowercased(), map[p] == nil { map[p] = v } }
        liveByChannel = map
    }

    /// The video list for the selected pill (changing pills doesn't reload the circles).
    func loadFeed(force: Bool = false) async {
        let key = pill.rawValue
        if !force, feedKey == key, !items.isEmpty { return }
        loading = true
        defer { loading = false }
        offset = 0
        if let f = try? await RumbleService.shared.followingFeed(pill: key, offset: 0) {
            guard pill.rawValue == key else { return }        // user switched pills meanwhile
            items = f.items.filter { $0.isShort != true }
            hasMore = f.hasMore
            offset = f.raw.count
            feedKey = key
            error = nil
        } else if items.isEmpty {
            error = "Couldn't load your feed. Pull to try again."
        }
    }

    func loadMore() async {
        guard hasMore, !loading else { return }
        loading = true
        defer { loading = false }
        if let f = try? await RumbleService.shared.followingFeed(pill: pill.rawValue, offset: offset) {
            let known = Set(items.map(\.id))
            items += f.items.filter { $0.isShort != true && !known.contains($0.id) }
            offset += f.raw.count
            hasMore = f.hasMore && !f.raw.isEmpty
        }
    }
}

struct MyFeedScreen: View {
    @ObservedObject private var model = MyFeedModel.shared
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var router: Router
    @State private var showLogin = false
    /// A channel tag chosen in the chips: shows the followed channels with that tag instead of a pill.
    @State private var selectedTag: UUID?
    @State private var tagItems: [VideoItem] = []
    @State private var tagLoading = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !account.loggedIn {
                    signInBanner
                }
                // A tag tab shows only that tag's channels in the circle row.
                if selectedTag == nil { channelCircles }
                if let id = selectedTag, let tag = library.data.channelTags.first(where: { $0.id == id }) {
                    tagSection(tag)
                } else {
                    feedList
                }
            }
        }
        .reportsScrollToHeader()
        .pullToRefresh {
            if let id = selectedTag { await loadTag(id, force: true) } else { await reload(force: true) }
        }
        .task(id: "\(account.loggedIn)|\(library.data.follows.count)") { await reload() }
        .task(id: selectedTag) { if let id = selectedTag { await loadTag(id) } }
        .onChange(of: model.pill) { _ in Task { await model.loadFeed() } }
        .appHeader("My Feed", chips: { pills })
        .miniPlayerSpace()
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(account) }
    }

    @ViewBuilder private var feedList: some View {
                CardGrid {
                    ForEach(model.items) { item in
                        Button { player.play(item) } label: { VideoCard(item: item) }.buttonStyle(.plain)
                            .onAppear { if item.id == model.items.last?.id { Task { await model.loadMore() } } }
                    }
                }
                if model.loading && model.items.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(50) }
                if !model.loading && model.items.isEmpty && model.error == nil {
                    Text(account.loggedIn ? "Nothing here yet." : "Follow channels and their newest videos show up here.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                }
                if let e = model.error { Text(e).font(.caption).foregroundStyle(.secondary).padding() }
    }

    // MARK: channel tags

    /// Followed channels (Rumble + this phone) carrying the tag. Tagged channels you don't follow only get badges.
    private func followedTagged(_ id: UUID) -> [ChannelRef] {
        var followed: [String: ChannelRef] = [:]
        for c in model.channels { followed[c.ref.path.lowercased()] = c.ref }
        for c in library.data.follows { followed[c.path.lowercased()] = followed[c.path.lowercased()] ?? c }
        return library.data.channels(tagged: id).compactMap { followed[$0.path.lowercased()] }
    }

    /// The followed-channel record (for live / recent rings), or a plain one for phone-only follows.
    private func followed(_ ref: ChannelRef) -> FollowedChannel {
        model.channels.first { $0.ref.path.lowercased() == ref.path.lowercased() }
            ?? FollowedChannel(ref: ref, lastActivity: nil, liveViewers: nil, followers: nil)
    }

    private func loadTag(_ id: UUID, force: Bool = false) async {
        let refs = followedTagged(id)
        guard !refs.isEmpty else { tagItems = []; return }
        tagLoading = true
        defer { tagLoading = false }
        let r = await RumbleService.shared.feed(refs, force: force)
        guard selectedTag == id else { return }
        tagItems = r.items.filter { $0.isShort != true }
    }

    @ViewBuilder private func tagSection(_ tag: ChannelTag) -> some View {
        let refs = followedTagged(tag.id)
        if refs.isEmpty {
            VStack(spacing: 8) {
                TagBadge(tag: tag)
                Text("None of the channels you follow have this tag yet. Long-press a video or use ⋯ on a channel page to tag it.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(40)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    // Same circles as the main row: red ring + LIVE when live, green when they posted recently.
                    ForEach(refs.map(followed)) { c in
                        Button { open(c) } label: { ChannelCircle(channel: c, recent: isRecent(c), live: liveVideo(c) != nil || c.isLive) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            CardGrid {
                ForEach(tagItems) { item in
                    Button { player.play(item) } label: { VideoCard(item: item) }.buttonStyle(.plain)
                }
            }
            if tagLoading && tagItems.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(40) }
        }
    }

    private func reload(force: Bool = false) async {
        await model.load(signedIn: account.loggedIn, localFollows: library.data.follows, force: force)
    }

    private var signInBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus").font(.title2).foregroundStyle(Color.rumbleGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text("See your Rumble subscriptions").font(.subheadline.weight(.semibold))
                Text("Showing channels followed on this phone.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign in") { showLogin = true }.buttonStyle(.borderedProminent).tint(.rumbleGreen).foregroundStyle(.black)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(12)
    }

    private var channelCircles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(sortedChannels) { c in
                    Button { open(c) } label: { ChannelCircle(channel: c, recent: isRecent(c), live: liveVideo(c) != nil || c.isLive) }
                        .buttonStyle(.plain)
                }
                NavigationLink(value: AppRoute.followingList) {
                    VStack(spacing: 6) {
                        Circle().fill(Color.secondary.opacity(0.18)).frame(width: 62, height: 62)
                            .overlay(Image(systemName: "chevron.right").font(.title3.weight(.semibold)))
                        Text("All").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    private var pills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(account.loggedIn ? MyFeedPill.allCases : [MyFeedPill.all]) { p in
                    Button { selectedTag = nil; model.pill = p } label: {
                        Chip(title: p.title, selected: selectedTag == nil && model.pill == p)
                    }
                    .buttonStyle(.plain)
                }
                if !library.data.channelTags.isEmpty {
                    Divider().frame(height: 22)
                    ForEach(library.data.channelTags) { t in
                        Button { selectedTag = selectedTag == t.id ? nil : t.id } label: {
                            Chip(title: t.name, selected: selectedTag == t.id, tint: Color(hex: t.color))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if account.loggedIn {
                    Divider().frame(height: 22)
                    NavigationLink(value: AppRoute.followedShorts) { Chip(title: "Shorts", asset: AppTab.shorts.asset) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    /// Live first, then most recent activity (Rumble already orders by activity).
    private var sortedChannels: [FollowedChannel] {
        model.channels.enumerated().sorted { a, b in
            let la = liveVideo(a.element) != nil || a.element.isLive, lb = liveVideo(b.element) != nil || b.element.isLive
            return la != lb ? la : a.offset < b.offset
        }.map(\.element)
    }

    private func liveVideo(_ c: FollowedChannel) -> VideoItem? { model.liveByChannel[c.ref.path.lowercased()] }

    private func isRecent(_ c: FollowedChannel) -> Bool {
        guard let d = c.lastActivity else { return false }
        return Date().timeIntervalSince(d) < 48 * 3600
    }

    private func open(_ c: FollowedChannel) {
        if let live = liveVideo(c) { player.play(live) } else { router.open(c.ref) }
    }
}

struct ChannelCircle: View {
    let channel: FollowedChannel
    var recent: Bool
    var live: Bool

    var body: some View {
        VStack(spacing: 6) {
            ChannelAvatar(name: channel.ref.name, url: channel.ref.avatar, size: 56, path: channel.ref.path)
                .padding(3)
                .overlay(Circle().stroke(live ? Color.rumbleRed : (recent ? Color.rumbleGreen : Color.clear), lineWidth: 3))
                .overlay(alignment: .bottom) {
                    if live {
                        Text("LIVE").font(.system(size: 9, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Color.rumbleRed, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white).offset(y: 6)
                    }
                }
            Text(channel.ref.name).font(.caption2).lineLimit(1).frame(width: 68)
        }
    }
}

struct FollowedShortsScreen: View {
    @StateObject private var shorts = ShortsModel(source: .following)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ShortsView(onClose: { dismiss() })
            .environmentObject(shorts)
            .onAppear { shorts.activate() }
            .onDisappear { shorts.deactivate() }
            .toolbar(.hidden, for: .tabBar)
    }
}

// MARK: - Account (like Rumble's account page)

struct AccountScreen: View {
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerModel
    @State private var showLogin = false
    @State private var prompted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if account.loggedIn { profileHeader } else { signedOutHeader }
                shelf("Watch History", icon: "clock.arrow.circlepath", route: .history,
                      items: library.data.history.prefix(12).map(\.video), empty: "Videos you watch show up here.")
                shelf("Watch Later", icon: "clock", route: .watchLater,
                      items: Array(library.data.watchLater.prefix(12)), empty: "Long-press any video and choose Watch Later.")
                VStack(spacing: 0) {
                    NavigationLink(value: AppRoute.downloads) { menuRow("Downloads", "arrow.down.circle") }
                    Divider().padding(.leading, 56)
                    // Rumble's merch store (the sidebar's "Shop" on rumble.com) opens in Safari.
                    Link(destination: URL(string: "https://www.stickermule.com/rumble")!) { menuRow("Shop", "bag") }
                    Divider().padding(.leading, 56)
                    NavigationLink(value: AppRoute.settings) { menuRow("Settings", "gearshape") }
                    if account.loggedIn {
                        Divider().padding(.leading, 56)
                        Button { Task { await account.signOut() } } label: { menuRow("Sign Out", "rectangle.portrait.and.arrow.right") }
                    }
                }
                .buttonStyle(.plain)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 12)
        }
        .reportsScrollToHeader()
        .pullToRefresh {
            await account.loadProfile()
            await WatchHistorySync.shared.sync(force: true)
        }
        .appHeader("Me")
        .miniPlayerSpace()
        .task(id: account.loggedIn) { if account.loggedIn { await account.loadProfile() } }
        .onAppear {
            if !account.loggedIn && !prompted { prompted = true; showLogin = true }
        }
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(account) }
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ChannelAvatar(name: account.username ?? "R", url: account.avatarURL, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.username ?? "Rumble user").font(.title2.weight(.bold))
                    Text([account.followersText.map { "\($0) Followers" }, account.followingCount.map { "\($0) Following" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let u = account.username {
                        NavigationLink(value: ChannelRef(path: "/user/\(u)", name: u, avatar: account.avatarURL)) {
                            Chip(title: "Your Videos", icon: "play.rectangle")
                        }
                    }
                    NavigationLink(value: AppRoute.followingList) { Chip(title: "Following", icon: "person.2") }
                    NavigationLink(value: AppRoute.earnings) { Chip(title: "Earnings", icon: "dollarsign") }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    private var signedOutHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle").font(.system(size: 54)).foregroundStyle(Color.rumbleGreen)
            Text("Sign in to Rumble").font(.title3.weight(.bold))
            Text("See your subscriptions, notifications, comments and earnings. History and Watch Later work without an account.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Sign in") { showLogin = true }
                .buttonStyle(.borderedProminent).tint(.rumbleGreen).foregroundStyle(.black)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
    }

    private func shelf(_ title: String, icon: String, route: AppRoute, items: [VideoItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon).font(.title3.weight(.bold))
                Spacer()
                NavigationLink(value: route) { Text("View all").font(.subheadline.weight(.semibold)) }
            }
            .padding(.horizontal, 12)
            if items.isEmpty {
                Text(empty).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { v in
                            Button { player.play(v) } label: { CompactCard(item: v, width: 220) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    private func menuRow(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).frame(width: 28)
            Text(title).font(.body.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

struct FollowingListScreen: View {
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var router: Router
    @State private var channels: [FollowedChannel] = []
    @State private var live: [String: VideoItem] = [:]
    @State private var loading = false

    var body: some View {
        List {
            ForEach(rows) { c in
                Button { open(c) } label: {
                    HStack(spacing: 12) {
                        ChannelAvatar(name: c.ref.name, url: c.ref.avatar, size: 48, path: c.ref.path)
                            .overlay(Circle().stroke(isLive(c) ? Color.rumbleRed : .clear, lineWidth: 2.5).padding(-3))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.ref.name).font(.body.weight(.semibold)).lineLimit(1)
                            if let f = c.followers { Text("\(CountFormat.short(f)) followers").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if isLive(c) {
                            Label(c.liveViewers.map { CountFormat.short($0) } ?? "LIVE", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption.weight(.bold)).foregroundStyle(Color.rumbleRed)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { idx in
                if !account.loggedIn { library.data.follows.remove(atOffsets: idx) }
            }
        }
        .listStyle(.plain)
        .overlay { if loading && rows.isEmpty { ProgressView() } else if rows.isEmpty { Text("Not following anyone yet.").foregroundStyle(.secondary) } }
        .navigationTitle("Following")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerSpace()
        .task {
            guard account.loggedIn else { return }
            if channels.isEmpty { channels = MyFeedModel.shared.channels }     // instant from cache
            loading = channels.isEmpty
            await MyFeedModel.shared.refreshChannels()
            channels = MyFeedModel.shared.channels
            if let f = try? await RumbleService.shared.followingFeed(pill: "live", offset: 0, limit: 30) {
                live = Dictionary(f.items.filter(\.isLive).compactMap { v in v.channelPath.map { ($0.lowercased(), v) } }, uniquingKeysWith: { a, _ in a })
            }
            loading = false
        }
    }

    private var rows: [FollowedChannel] {
        account.loggedIn ? channels
            : library.data.follows.map { FollowedChannel(ref: $0, lastActivity: nil, liveViewers: nil, followers: nil) }
    }
    private func isLive(_ c: FollowedChannel) -> Bool { c.isLive || live[c.ref.path.lowercased()] != nil }
    private func open(_ c: FollowedChannel) {
        if let v = live[c.ref.path.lowercased()] { player.play(v) } else { router.open(c.ref) }
    }
}

struct EarningsScreen: View {
    @EnvironmentObject var account: AccountStore
    @State private var lines: [EarningsLine] = []
    @State private var error: String?

    var body: some View {
        List {
            if let total = lines.first(where: { $0.label == "Total" }) {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Total Earnings").font(.subheadline).foregroundStyle(.secondary)
                        Text(total.amount).font(.system(size: 40, weight: .bold))
                    }
                    .padding(.vertical, 6)
                }
            }
            Section("Estimated Earnings") {
                ForEach(lines.filter { $0.label != "Total" }) { l in LabeledContent(l.label, value: l.amount) }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle("Earnings")
        .miniPlayerSpace()
        .task {
            do { lines = try await account.earnings() } catch { self.error = error.localizedDescription }
        }
    }
}

struct HistoryScreen: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var player: PlayerModel
    @ObservedObject private var sync = WatchHistorySync.shared

    var body: some View {
        List {
            ForEach(library.data.history) { h in
                Button { player.play(h.video) } label: { VideoRow(item: h.video) }.buttonStyle(.plain)
            }
            .onDelete { library.data.history.remove(atOffsets: $0) }
        }
        .listStyle(.plain)
        .overlay {
            if library.data.history.isEmpty {
                if sync.syncing { ProgressView() } else { Text("Videos you watch show up here.").foregroundStyle(.secondary) }
            }
        }
        .pullToRefresh { await sync.sync(force: true) }
        .task { await sync.sync() }
        .navigationTitle("Watch History")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerSpace()
    }
}

struct WatchLaterScreen: View {
    enum Source: String, CaseIterable, Identifiable { case phone = "This phone", rumble = "Rumble"; var id: String { rawValue } }
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var player: PlayerModel
    @State private var source: Source = .phone

    var body: some View {
        VStack(spacing: 0) {
            if account.loggedIn {
                Picker("Source", selection: $source) { ForEach(Source.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 8)
            }
            if source == .rumble && account.loggedIn {
                ListingView(model: ListingModel { page in try await RumbleService.shared.listing("/playlists/watch-later", page: page) },
                            style: .rows)
            } else {
                List {
                    ForEach(library.data.watchLater) { v in
                        Button { player.play(v) } label: { VideoRow(item: v) }.buttonStyle(.plain)
                    }
                    .onDelete { library.data.watchLater.remove(atOffsets: $0) }
                    .onMove { library.data.watchLater.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .overlay { if library.data.watchLater.isEmpty { Text("Long-press any video and choose Watch Later.").foregroundStyle(.secondary).padding(30) } }
                .toolbar { EditButton() }
            }
        }
        .navigationTitle("Watch Later")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerSpace()
    }
}
