import SwiftUI
import UIKit

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

    /// Notification bell / tapped alert: push Notifications on the current tab.
    func showInbox() {
        var p = paths[tab] ?? NavigationPath()
        p.append(AppRoute.inbox)
        paths[tab] = p
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
            .overlay {
                if let p = progress, p >= 0.95 { Color.black.opacity(0.35) }
            }
            .overlay(alignment: .topLeading) {
                if let p = progress, p >= 0.95 {
                    Label("Watched", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white).padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                if let p = progress, p > 0.01 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.35))
                            Rectangle().fill(Color.rumbleGreen).frame(width: g.size.width * min(1, p))
                        }
                        .frame(height: 4)
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
    @State private var image: UIImage?

    var body: some View {
        Circle().fill(Color.rumbleGreen.opacity(0.25))
            .overlay {
                if let img = image ?? url.flatMap({ AvatarCache.shared.cached($0) }) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if url == nil {
                    Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(Color.rumbleGreen)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .task(id: url) {
                guard let url, AvatarCache.shared.cached(url) == nil else { return }
                image = await AvatarCache.shared.load(url)
            }
    }
}

/// Small in-memory image cache for channel pictures, so circles and avatars draw instantly once seen.
final class AvatarCache: @unchecked Sendable {
    static let shared = AvatarCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 400 }

    func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    func load(_ url: String) async -> UIImage? {
        if let i = cached(url) { return i }
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u, cachePolicy: .returnCacheDataElseLoad)
        r.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: r), let img = UIImage(data: res.0) else { return nil }
        // decode once at a small size so scrolling stays smooth
        let k = 160 / max(img.size.width, img.size.height, 1)
        let thumb = k < 1 ? (await img.byPreparingThumbnail(ofSize: CGSize(width: img.size.width * k, height: img.size.height * k)) ?? img) : img
        cache.setObject(thumb, forKey: url as NSString)
        return thumb
    }

    func prefetch(_ urls: [String]) {
        for u in urls where cached(u) == nil { Task.detached(priority: .utility) { _ = await self.load(u) } }
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

    private var progress: Double? { library.data.watchFraction(for: item) }
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

    private var progress: Double? { library.data.watchFraction(for: item) }
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
            if !item.isLive {
                if DownloadManager.shared.isDownloaded(item.id) {
                    Button(role: .destructive) { DownloadManager.shared.delete(item.id) } label: { Label("Remove download", systemImage: "trash") }
                } else {
                    Button { DownloadManager.shared.download(item) } label: { Label("Download", systemImage: "arrow.down.circle") }
                }
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
    var filter: ContentFilter = .all
    @ViewBuilder var header: () -> Header
    @EnvironmentObject var player: PlayerModel

    enum Style { case cards, rows }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: style == .rows ? 12 : 0) {
                header()
                let shown = model.items.filter(filter.keep)
                CardGrid {
                    ForEach(shown) { item in
                        Button { player.play(item) } label: {
                            if style == .cards { VideoCard(item: item) } else { VideoRow(item: item).padding(.horizontal, 12) }
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if item.id == shown.last?.id { Task { await model.loadMore() } }
                        }
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
        } else if model.loadedOnce && model.items.filter(filter.keep).isEmpty {
            VStack(spacing: 10) {
                Text(model.items.isEmpty ? "Nothing here." : "Nothing matching this filter yet.").foregroundStyle(.secondary)
                if model.hasNext && !model.items.isEmpty {
                    Button("Load more") { Task { await model.loadMore() } }.buttonStyle(.bordered)
                }
            }
            .padding(40)
        } else if model.hasNext && !model.items.isEmpty && model.items.filter(filter.keep).count < 4 {
            Button("Load more") { Task { await model.loadMore() } }.buttonStyle(.bordered).padding(20)
        }
    }
}

extension ListingView where Header == EmptyView {
    init(model: ListingModel, style: Style = .cards, filter: ContentFilter = .all) {
        self.init(model: model, style: style, filter: filter, header: { EmptyView() })
    }
}


// MARK: - Tappable timestamps

enum SeekLinks {
    static let scheme = "rumbletube-seek"

    /// Turns "12:34" in text into links that seek the player.
    static func attributed(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        for hit in Timestamps.find(in: text) {
            guard let lo = AttributedString.Index(hit.range.lowerBound, within: a),
                  let hi = AttributedString.Index(hit.range.upperBound, within: a) else { continue }
            a[lo..<hi].link = URL(string: "\(scheme)://t/\(Int(hit.seconds))")
            a[lo..<hi].foregroundColor = .accentColor
        }
        return a
    }

    static func seconds(_ url: URL) -> Double? {
        url.scheme == scheme ? Double(url.lastPathComponent) : nil
    }
}

extension View {
    /// Handles taps on timestamp links: seeks `video` (opening it first if something else is playing).
    func seekLinks(for video: VideoItem?, player: PlayerModel, onSeek: (() -> Void)? = nil) -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard let t = SeekLinks.seconds(url) else { return .systemAction }
            if let v = video, player.item?.id != v.id { player.play(v, at: t) } else { player.seek(to: t) }
            player.expanded = true
            onSeek?()
            return .handled
        })
    }
}


/// Cards in one column on iPhone, an adaptive grid on iPad / wide windows.
struct CardGrid<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var hsc
    @ViewBuilder var content: () -> Content

    var body: some View {
        if hsc == .regular {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 4) { content() }
                .padding(.horizontal, 8)
        } else {
            content()
        }
    }
}
