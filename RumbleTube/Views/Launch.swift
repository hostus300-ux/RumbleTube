import SwiftUI

/// Cold-start gate: an animated splash plays over the app while Home loads underneath.
/// Reveals when Home has content (never sooner than 0.4 s, never later than 2 s).
@MainActor
final class LaunchGate: ObservableObject {
    @Published private(set) var ready = false
    private var started = false

    func run() async {
        guard !started else { return }
        started = true
        let home = HomeModel.shared
        let start = Date()
        let hadCache = home.loadCache()
        Task { await home.load() }                                    // always revalidate
        if !hadCache {
            // wait for fresh data or the 2 s limit, whichever comes first
            let deadline = Date().addingTimeInterval(2)
            while home.page == nil && home.error == nil && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        await ImagePrefetch.first(home.page, count: 8, timeout: max(0.2, 2 - Date().timeIntervalSince(start)))
        let wait = 0.4 - Date().timeIntervalSince(start)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        ready = true
        // Warm My Feed's circles in the background so the tab is ready when you get there.
        Task {
            if !AccountStore.shared.loggedIn { await AccountStore.shared.refreshStatus() }
            if AccountStore.shared.loggedIn {
                await MyFeedModel.shared.refreshChannels()
                await AccountStore.shared.loadProfile()          // profile picture for the "Me" tab
                await WatchHistorySync.shared.sync()
            }
        }
    }
}

/// Warms URLCache with the first thumbnails so Home appears with pictures, not grey boxes.
enum ImagePrefetch {
    static func first(_ page: HomePage?, count: Int, timeout: TimeInterval) async {
        guard let page else { return }
        let urls = (page.hero + page.rows.flatMap(\.items)).compactMap { $0.thumbnail.flatMap(URL.init(string:)) }.prefix(count)
        await withTaskGroup(of: Void.self) { g in
            for u in urls {
                g.addTask {
                    var r = URLRequest(url: u, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
                    r.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
                    _ = try? await URLSession.shared.data(for: r)
                }
            }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await g.next()            // first image or the timeout…
            for await _ in g {}       // …then let the rest finish (each has its own timeout)
        }
    }
}

/// The splash itself: the app glyph pulses in, then the whole layer lifts away.
struct SplashView: View {
    var reveal: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false

    var body: some View {
        ZStack {
            SplashBackground().ignoresSafeArea()
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(hex: 0x85C742))
                    .frame(width: 128, height: 94)
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 40, weight: .black))
                    RoundedRectangle(cornerRadius: 3).frame(width: 7, height: 42)
                }
                .foregroundStyle(Color(hex: 0x13200B))
                .offset(x: appear || reduceMotion ? 6 : -6)
            }
            .scaleEffect(reveal && !reduceMotion ? 1.6 : (appear ? 1 : 0.86))
            .opacity(appear ? 1 : 0)
        }
        .opacity(reveal ? 0 : 1)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.7)) { appear = true }
        }
        .allowsHitTesting(!reveal)
        .accessibilityHidden(true)
    }
}

/// Deep navy with faint green rings spreading from the left edge.
struct SplashBackground: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x0A1724)))
            let center = CGPoint(x: -size.width * 0.02, y: size.height * 0.5)
            let spacing = max(16, size.width / 21)
            let maxR = hypot(size.width * 1.05, size.height * 0.55)
            var r = spacing
            while r < maxR {
                let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                ctx.stroke(ring, with: .color(Color(hex: 0x85C742).opacity(0.11)), lineWidth: 2.4)
                r += spacing
            }
        }
    }
}
