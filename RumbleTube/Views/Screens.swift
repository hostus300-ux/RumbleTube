import SwiftUI

// MARK: - Home (subscriptions feed)

@MainActor
final class FeedModel: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var failed: [ChannelRef] = []
    @Published var loading = false
    @Published var loadedFor: [String] = []

    func load(_ follows: [ChannelRef], force: Bool = false) async {
        let key = follows.map(\.id)
        guard force || key != loadedFor else { return }
        loading = true
        let r = await RumbleService.shared.feed(follows, force: force)
        items = r.items; failed = r.failed; loadedFor = key
        loading = false
    }
}

struct HomeView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var router: Router
    @StateObject private var feed = FeedModel()

    var body: some View {
        Group {
            if library.data.follows.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "person.2.crop.square.stack").font(.system(size: 48)).foregroundStyle(Color.rumbleGreen)
                    Text("Your feed is empty").font(.title3.weight(.semibold))
                    Text("Follow channels and their newest videos show up here, newest first.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Explore Rumble") { router.tab = .explore }.buttonStyle(.borderedProminent).tint(.rumbleGreen)
                        .foregroundStyle(.black)
                }
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        channelStrip
                        if feed.loading && feed.items.isEmpty { ProgressView().padding(40) }
                        ForEach(feed.items) { item in
                            Button { player.play(item) } label: { VideoCard(item: item) }.buttonStyle(.plain)
                        }
                        if !feed.failed.isEmpty {
                            Text("Couldn't load: \(feed.failed.map(\.name).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary).padding()
                        }
                    }
                }
                .refreshable { await feed.load(library.data.follows, force: true) }
            }
        }
        .navigationTitle("Home")
        .task(id: library.data.follows.map(\.id)) { await feed.load(library.data.follows) }
    }

    private var channelStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(library.data.follows) { c in
                    NavigationLink(value: c) {
                        VStack(spacing: 4) {
                            ChannelAvatar(name: c.name, url: c.avatar, size: 52)
                            Text(c.name).font(.caption2).lineLimit(1).frame(width: 64)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }
}

// MARK: - Explore

struct ExploreView: View {
    @State private var section: ExploreSection = .live

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(ExploreSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.vertical, 8)
            ListingView(model: ListingModel { page in try await RumbleService.shared.explore(section, page: page) })
                .id(section)
        }
        .navigationTitle("Explore")
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var router: Router
    @State private var text = ""
    @State private var submitted = ""
    @State private var sort: SearchSort = .relevance

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
            if submitted.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Search Rumble, or paste a rumble.com link.").foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                Picker("Sort", selection: $sort) {
                    ForEach(SearchSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal, 12).padding(.bottom, 6)
                let q = submitted, s = sort
                ListingView(model: ListingModel { page in try await RumbleService.shared.search(q, sort: s, page: page) })
                    .id("\(q)|\(s.rawValue)")
            }
        }
        .navigationTitle("Search")
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or paste link")
        .onSubmit(of: .search) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let link = RumbleService.item(fromLink: t) { player.play(link) } else if !t.isEmpty { submitted = t }
        }
    }
}

// MARK: - Channel

struct ChannelView: View {
    let channel: ChannelRef
    @EnvironmentObject var library: LibraryStore
    @StateObject private var model: ListingModel

    init(channel: ChannelRef) {
        self.channel = channel
        let path = channel.path
        _model = StateObject(wrappedValue: ListingModel { page in try await RumbleService.shared.channel(path, page: page) })
    }

    var body: some View {
        ListingView(model: model, style: .rows) { header.padding(.bottom, 8) }
            .navigationTitle(model.header?.name ?? channel.name)
            .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        let h = model.header
        let ref = ChannelRef(path: channel.path, name: h?.name ?? channel.name, avatar: h?.avatar ?? channel.avatar)
        let following = library.data.isFollowing(channel.path)
        return VStack(spacing: 10) {
            if let b = h?.banner, let url = URL(string: b) {
                AsyncImage(url: url) { $0.image?.resizable().scaledToFill() }
                    .frame(height: 90).frame(maxWidth: .infinity).clipped()
            }
            HStack(spacing: 12) {
                ChannelAvatar(name: ref.name, url: ref.avatar, size: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ref.name).font(.title3.weight(.bold)).lineLimit(2)
                    if let f = h?.followers { Text("\(f) followers").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            Button {
                library.data.toggleFollow(ref)
            } label: {
                Text(following ? "Following" : "Follow").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(following ? Color.secondary.opacity(0.3) : Color.rumbleGreen)
            .foregroundStyle(following ? Color.primary : Color.black)
            .padding(.horizontal, 12)
        }
        .onChange(of: h?.avatar) { avatar in
            // keep the stored follow's avatar/name fresh
            if let i = library.data.follows.firstIndex(where: { $0.id == channel.id }), let avatar {
                library.data.follows[i].avatar = avatar
                if let n = h?.name { library.data.follows[i].name = n }
            }
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable { case history = "History", later = "Watch Later", following = "Following"; var id: String { rawValue } }
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerModel
    @State private var section: Section = .history

    var body: some View {
        VStack(spacing: 0) {
            Picker("Library", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 8)
            List {
                switch section {
                case .history:
                    ForEach(library.data.history) { h in
                        Button { player.play(h.video) } label: { VideoRow(item: h.video) }.buttonStyle(.plain)
                    }
                    .onDelete { library.data.history.remove(atOffsets: $0) }
                case .later:
                    ForEach(library.data.watchLater) { v in
                        Button { player.play(v) } label: { VideoRow(item: v) }.buttonStyle(.plain)
                    }
                    .onDelete { library.data.watchLater.remove(atOffsets: $0) }
                    .onMove { library.data.watchLater.move(fromOffsets: $0, toOffset: $1) }
                case .following:
                    ForEach(library.data.follows) { c in
                        NavigationLink(value: c) {
                            HStack(spacing: 12) { ChannelAvatar(name: c.name, url: c.avatar); Text(c.name) }
                        }
                    }
                    .onDelete { library.data.follows.remove(atOffsets: $0) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if isEmpty {
                    Text(emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(40)
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { if section == .later { EditButton() } }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
        }
    }

    private var isEmpty: Bool {
        switch section {
        case .history: return library.data.history.isEmpty
        case .later: return library.data.watchLater.isEmpty
        case .following: return library.data.follows.isEmpty
        }
    }

    private var emptyText: String {
        switch section {
        case .history: return "Videos you watch show up here."
        case .later: return "Long-press any video and choose Watch Later."
        case .following: return "Follow channels from their page or the player."
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var confirmClear = false

    private let qualities: [(String, Int?)] = [("Auto (adaptive)", nil), ("1080p", 1080), ("720p", 720), ("480p", 480), ("360p", 360)]

    var body: some View {
        Form {
            AccountSettingsSection()
            Section {
                NavigationLink {
                    SkipSettingsView()
                } label: {
                    Label("RumbleSkip", systemImage: "forward.end.alt")
                }
            } footer: {
                Text("Skip sponsors, intros and more — community segments plus SponsorBlock data for videos also on YouTube.")
            }
            Section("Playback") {
                Picker("Default quality", selection: Binding(get: { library.data.preferredHeight ?? 0 },
                                                             set: { library.data.preferredHeight = $0 == 0 ? nil : $0 })) {
                    ForEach(qualities.indices, id: \.self) { i in Text(qualities[i].0).tag(qualities[i].1 ?? 0) }
                }
            }
            Section("Data") {
                Button("Clear watch history", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear history and resume positions?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear", role: .destructive) { library.data.history = []; library.data.positions = [:] }
                    }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                Text("RumbleTube is an unofficial client. It reads public rumble.com pages; videos and channels belong to their creators.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
