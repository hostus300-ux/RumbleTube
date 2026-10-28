import SwiftUI
import UIKit

/// Current accent (set from preferences; the root view rebuilds when it changes).
enum Theme {
    static var accentHex: UInt32 = AccentChoice.green.hex
}

extension Color {
    static var rumbleGreen: Color { Color(hex: Theme.accentHex) }
    /// rumble.com's live red (#F23160), used for every LIVE badge, ring and Live button.
    static let rumbleRed = Color(hex: 0xF23160)
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
    /// Your channel tags, shown as badges in the top-left corner.
    var tags: [ChannelTag] = []

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
            // Live streams get a rumble-red outline so they stand out in any list.
            .overlay { if item.isLive { Rectangle().strokeBorder(Color.rumbleRed, lineWidth: 3) } }
            .overlay(alignment: .bottomTrailing) {
                if item.isLive {
                    badge(item.watching.map { "● LIVE · \(CountFormat.short($0))" } ?? "● LIVE", Color.rumbleRed)
                } else if item.upcoming == true {
                    badge("UPCOMING", Color.yellow.opacity(0.9), fg: .black)
                } else if let d = item.duration {
                    badge(d, Color.black.opacity(0.75))
                }
            }
            .overlay {
                if let p = progress, p >= 0.95 { Color.black.opacity(0.35) }
            }
            .overlay(alignment: .topLeading) { if progress ?? 0 < 0.95 { ThumbnailTags(tags: tags) } }
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
    /// "/c/Name": lets the picture be found when the list didn't include it.
    var path: String? = nil
    @State private var image: UIImage?

    private var known: String? { url ?? path.flatMap { AvatarDirectory.shared.url(for: $0) } }

    var body: some View {
        Circle().fill(Color.rumbleGreen.opacity(0.25))
            .overlay {
                if let img = image ?? known.flatMap({ AvatarCache.shared.cached($0) }) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(Color.rumbleGreen)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .task(id: (url ?? "") + "|" + (path ?? "")) {
                if let url, let path { AvatarDirectory.shared.learn(path: path, url: url) }
                var u = known
                if u == nil, let path { u = await AvatarDirectory.shared.resolve(path) }   // look it up once
                guard let u else { return }
                if let c = AvatarCache.shared.cached(u) { image = c; return }
                image = await AvatarCache.shared.load(u)
            }
    }
}

/// Channel path → picture URL, learned from every list, channel page and followed list the app sees,
/// and looked up (once per channel) when a list didn't include it. Kept between launches.
final class AvatarDirectory: @unchecked Sendable {
    static let shared = AvatarDirectory()
    private let lock = NSLock()
    private var map: [String: String]
    private var pending: [String: Task<String?, Never>] = [:]
    private var misses = Set<String>()
    private var dirty = false
    private let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("avatars.json")

    private init() {
        map = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private func key(_ path: String) -> String { path.lowercased().components(separatedBy: "?")[0] }

    func url(for path: String) -> String? { lock.lock(); defer { lock.unlock() }; return map[key(path)] }

    func learn(path: String, url: String) {
        lock.lock()
        let k = key(path)
        if map[k] != url { map[k] = url; dirty = true }
        lock.unlock()
        scheduleSave()
    }

    func learn(_ items: [VideoItem]) {
        for v in items { if let p = v.channelPath, let a = v.channelAvatar { learn(path: p, url: a) } }
    }

    /// Fetch the channel page once to find its picture (shared by every avatar of that channel on screen).
    func resolve(_ path: String) async -> String? {
        let k = key(path)
        lock.lock()
        if let u = map[k] { lock.unlock(); return u }
        if misses.contains(k) { lock.unlock(); return nil }
        if let t = pending[k] { lock.unlock(); return await t.value }
        let t = Task<String?, Never> {
            await AvatarLookupGate.shared.enter()
            let u = await Task { @MainActor in (try? await RumbleService.shared.channel(path))?.channel?.avatar }.value
            await AvatarLookupGate.shared.leave()
            return u
        }
        pending[k] = t
        lock.unlock()
        let u = await t.value
        lock.lock()
        pending[k] = nil
        if let u { map[k] = u; dirty = true } else { misses.insert(k) }
        lock.unlock()
        scheduleSave()
        return u
    }

    private var saveScheduled = false
    private func scheduleSave() {
        lock.lock()
        guard dirty, !saveScheduled else { lock.unlock(); return }
        saveScheduled = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.map.count > 5000 ? [:] : self.map
            self.dirty = false; self.saveScheduled = false
            self.lock.unlock()
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: self.file, options: .atomic) }
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

    var body: some View { MuteGate(item: item) { card } }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            Thumbnail(item: item, progress: progress, tags: library.data.tags(for: item.channelPath))
            HStack(alignment: .top, spacing: 10) {
                ChannelAvatar(name: item.channelName ?? "?", url: item.channelAvatar, path: item.channelPath)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        .foregroundStyle(.primary).multilineTextAlignment(.leading)
                    HStack(spacing: 3) {
                        if let c = item.channelName { Text(c).lineLimit(1) }
                        if item.channelVerified == true { VerifiedBadge(size: 11) }
                        let meta = metaLine(item)
                        if !meta.isEmpty { Text((item.channelName == nil ? "" : "· ") + meta).lineLimit(1) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
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

    var body: some View { MuteGate(item: item) { row } }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(item: item, progress: progress, tags: library.data.tags(for: item.channelPath))
                .frame(width: 160).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                if let c = item.channelName {
                    HStack(spacing: 3) {
                        Text(c).lineLimit(1)
                        if item.channelVerified == true { VerifiedBadge(size: 11) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
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
            if let c = item.channel {
                Button { TagUI.shared.tag(c) } label: { Label("Tag channel…", systemImage: "tag") }
            }
            if item.channelName != nil {
                if let e = library.data.muteEntry(for: item) {
                    Button { library.data.unmute(e.key) } label: { Label("Unmute channel", systemImage: "speaker.wave.2") }
                } else {
                    Button { MuteUI.shared.muteChannel(item) } label: { Label("Mute channel…", systemImage: "speaker.slash") }
                }
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
        var cancelled = false
        defer { loading = false; if !cancelled { loadedOnce = true } }
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
            // Leaving a page cancels its request; that's not a failure, and it should load again next time.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { cancelled = true }
            else { self.error = error.localizedDescription }
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
        .pullToRefresh { await model.reload() }
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
        // iPad only: big iPhones report a regular width in landscape for a moment while rotating.
        if hsc == .regular && UIDevice.current.userInterfaceIdiom == .pad {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 4) { content() }
                .padding(.horizontal, 8)
        } else {
            content()
        }
    }
}


/// At most three channel-page lookups for missing pictures at a time.
actor AvatarLookupGate {
    static let shared = AvatarLookupGate()
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        if running < 3 { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}

/// Verified creators: a green rounded play-shape with a check, in the spirit of rumble.com's badge
/// (drawn for this app, not copied).
struct VerifiedBadge: View {
    var size: CGFloat = 14
    var body: some View {
        ZStack {
            RoundedPlayShape().fill(Color(hex: 0x74CC1D))
            CheckShape()
                .stroke(Color(hex: 0x0E1A06), style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round, lineJoin: .round))
                .padding(size * 0.27)
                .offset(x: -size * 0.04)
        }
        .frame(width: size * 1.08, height: size)
        .accessibilityElement()
        .accessibilityLabel("Verified")
    }
}

/// A play triangle with generously rounded corners.
struct RoundedPlayShape: Shape {
    func path(in r: CGRect) -> Path {
        let a = CGPoint(x: r.minX + r.width * 0.06, y: r.minY + r.height * 0.02)
        let b = CGPoint(x: r.minX + r.width * 0.06, y: r.maxY - r.height * 0.02)
        let c = CGPoint(x: r.maxX - r.width * 0.02, y: r.midY)
        let rad = min(r.width, r.height) * 0.26
        var p = Path()
        p.move(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        p.addArc(tangent1End: b, tangent2End: c, radius: rad)
        p.addArc(tangent1End: c, tangent2End: a, radius: rad)
        p.addArc(tangent1End: a, tangent2End: b, radius: rad)
        p.closeSubpath()
        return p
    }
}

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.55))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.maxY - r.height * 0.12))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.05, y: r.minY + r.height * 0.18))
        return p
    }
}


// MARK: - Pull to refresh with visible feedback

/// `.refreshable` plus a small animated banner: "Refreshing…" while it really reloads, then "Updated".
private struct RefreshFeedback: ViewModifier {
    let action: () async -> Void
    @State private var phase: Phase = .idle
    enum Phase: Equatable { case idle, refreshing, done }

    func body(content: Content) -> some View {
        content
            .refreshable {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { phase = .refreshing }
                let started = Date()
                await action()
                // Keep the animation up long enough to be seen.
                let left = 0.6 - Date().timeIntervalSince(started)
                if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { phase = .done }
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    withAnimation(.easeOut(duration: 0.25)) { if phase == .done { phase = .idle } }
                }
            }
            .overlay(alignment: .top) {
                if phase != .idle {
                    RefreshBanner(done: phase == .done)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct RefreshBanner: View {
    let done: Bool
    @State private var spin = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.rumbleGreen)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Circle().trim(from: 0, to: 0.72)
                        .stroke(Color.rumbleGreen, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
                    Image(systemName: "play.fill").font(.system(size: 7, weight: .black)).foregroundStyle(Color.rumbleGreen)
                }
            }
            .frame(width: 18, height: 18)
            Text(done ? "Updated" : "Refreshing…").font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .onAppear { spin = true }
    }
}

extension View {
    /// Pull to refresh with an animated "Refreshing… / Updated" banner.
    func pullToRefresh(_ action: @escaping () async -> Void) -> some View {
        modifier(RefreshFeedback(action: action))
    }
}
