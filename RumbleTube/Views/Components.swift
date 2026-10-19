import SwiftUI

/// Current accent (set from preferences; the root view rebuilds when it changes).
enum Theme {
    static var accentHex: UInt32 = AccentChoice.green.hex
}

extension Color {
    static var rumbleGreen: Color { Color(hex: Theme.accentHex) }
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension SkipCategory {
    var color: Color { Color(hex: hex) }
}

// MARK: - Navigation

@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    typealias Tab = AppTab
    @Published var tab: Tab = .home
    @Published var paths: [Tab: NavigationPath] = [:]

    func path(_ tab: Tab) -> Binding<NavigationPath> {
        Binding(get: { self.paths[tab] ?? NavigationPath() }, set: { self.paths[tab] = $0 })
    }

    func open(_ channel: ChannelRef) {
        PlayerModel.shared.expanded = false
        var p = paths[tab] ?? NavigationPath()
        p.append(channel)
        paths[tab] = p
    }

    /// rumbletube://open?url=…, rumbletube://rumble.com/v…, or a plain rumble.com URL
    func handle(_ url: URL) {
        var s = url.absoluteString
        if let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let inner = c.queryItems?.first(where: { $0.name == "url" })?.value { s = inner }
        s = s.replacingOccurrences(of: "rumbletube://", with: "https://")
        if let item = RumbleService.item(fromLink: s) { PlayerModel.shared.play(item); return }
        if let path = RumbleURL.channelPath(from: s) ?? URL(string: s).flatMap({ RumbleURL.channelPath(from: $0.path) }) {
            open(ChannelRef(path: path, name: String(path.split(separator: "/").last ?? "")))
        }
    }
}

// MARK: - Thumbnails & rows

struct Thumbnail: View {
    let item: VideoItem
    var progress: Double? = nil

    var body: some View {
        Color.gray.opacity(0.18)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let s = item.thumbnail, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else { Color.clear }
                    }
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if item.isLive {
                    badge("LIVE", Color.red)
                } else if item.upcoming == true {
                    badge("UPCOMING", Color.yellow.opacity(0.9), fg: .black)
                } else if let d = item.duration {
                    badge(d, Color.black.opacity(0.75))
                }
            }
            .overlay(alignment: .bottom) {
                if let p = progress, p > 0.02 {
                    GeometryReader { g in
                        Rectangle().fill(Color.red).frame(width: g.size.width * min(1, p), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
    }

    private func badge(_ text: String, _ bg: Color, fg: Color = .white) -> some View {
        Text(text).font(.caption2.weight(.bold)).monospacedDigit()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(fg)
            .padding(6)
    }
}

struct ChannelAvatar: View {
    let name: String
    var url: String?
    var size: CGFloat = 36

    var body: some View {
        Circle().fill(Color.rumbleGreen.opacity(0.25))
            .overlay {
                if let u = url, let url = URL(string: u) {
                    AsyncImage(url: url) { $0.image?.resizable().scaledToFill() }
                } else {
                    Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(Color.rumbleGreen)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

func metaLine(_ item: VideoItem) -> String {
    var parts: [String] = []
    if let v = item.views, !v.isEmpty { parts.append("\(v) views") }
    if let d = item.publishedDate { parts.append(DateParsing.relative(d)) }
    else if let t = item.publishedText { parts.append(t) }
    return parts.joined(separator: " · ")
}

/// Large YouTube-style card.
struct VideoCard: View {
    let item: VideoItem
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Thumbnail(item: item, progress: progress)
            HStack(alignment: .top, spacing: 10) {
                ChannelAvatar(name: item.channelName ?? "?", url: item.channelAvatar)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        .foregroundStyle(.primary).multilineTextAlignment(.leading)
                    Text([item.channelName, metaLine(item)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .videoContextMenu(item)
    }

    private var progress: Double? {
        guard let p = library.data.positions[item.id], let d = item.durationSeconds, d > 0 else { return nil }
        return p / d
    }
}

/// Compact row (thumbnail left).
struct VideoRow: View {
    let item: VideoItem
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(item: item, progress: progress).frame(width: 160).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                if let c = item.channelName { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(metaLine(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .videoContextMenu(item)
    }

    private var progress: Double? {
        guard let p = library.data.positions[item.id], let d = item.durationSeconds, d > 0 else { return nil }
        return p / d
    }
}

struct VideoContextMenu: ViewModifier {
    let item: VideoItem
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var router: Router

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                library.data.toggleWatchLater(item)
            } label: {
                Label(library.data.inWatchLater(item.id) ? "Remove from Watch Later" : "Watch Later",
                      systemImage: library.data.inWatchLater(item.id) ? "clock.badge.xmark" : "clock")
            }
            if let c = item.channel {
                Button { router.open(c) } label: { Label("Go to channel", systemImage: "person.crop.square") }
            }
            if let url = URL(string: item.url) {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

extension View {
    func videoContextMenu(_ item: VideoItem) -> some View { modifier(VideoContextMenu(item: item)) }
}

// MARK: - Paginated listing

@MainActor
final class ListingModel: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var header: ChannelHeader?
    @Published var loading = false
    @Published var error: String?
    @Published var hasNext = true
    @Published var loadedOnce = false
    private var page = 0
    private let loader: (Int) async throws -> ListingPage

    init(loader: @escaping (Int) async throws -> ListingPage) { self.loader = loader }

    func reload() async {
        page = 0; hasNext = true; error = nil
        await loadMore(reset: true)
    }

    func loadMore(reset: Bool = false) async {
        guard !loading, hasNext else { return }
        loading = true
        defer { loading = false; loadedOnce = true }
        do {
            let next = page + 1
            let result = try await loader(next)
            page = next
            if reset { items = [] }
            if header == nil { header = result.channel }
            let known = Set(items.map(\.id))
            let fresh = result.items.filter { !known.contains($0.id) }
            items += fresh
            hasNext = result.hasNext && !fresh.isEmpty
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
}

struct ListingView<Header: View>: View {
    @StateObject var model: ListingModel
    var style: Style = .cards
    @ViewBuilder var header: () -> Header
    @EnvironmentObject var player: PlayerModel

    enum Style { case cards, rows }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: style == .rows ? 12 : 0) {
                header()
                ForEach(model.items) { item in
                    Button { player.play(item) } label: {
                        if style == .cards { VideoCard(item: item) } else { VideoRow(item: item).padding(.horizontal, 12) }
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.id == model.items.last?.id { Task { await model.loadMore() } }
                    }
                }
                footer
            }
        }
        .refreshable { await model.reload() }
        .task { if !model.loadedOnce { await model.loadMore() } }
    }

    @ViewBuilder private var footer: some View {
        if model.loading {
            ProgressView().padding(30)
        } else if let e = model.error {
            VStack(spacing: 10) {
                Text(e).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await model.reload() } }.buttonStyle(.bordered)
            }.padding(30)
        } else if model.loadedOnce && model.items.isEmpty {
            Text("Nothing here.").foregroundStyle(.secondary).padding(40)
        }
    }
}

extension ListingView where Header == EmptyView {
    init(model: ListingModel, style: Style = .cards) {
        self.init(model: model, style: style, header: { EmptyView() })
    }
}
