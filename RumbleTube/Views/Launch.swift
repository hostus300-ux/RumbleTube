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
    @State private var start = Date()

    var body: some View {
        ZStack {
            SplashBackground().ignoresSafeArea()
            TimelineView(.animation(paused: reduceMotion || reveal)) { tl in
                SplashMark(elapsed: reduceMotion ? 5 : tl.date.timeIntervalSince(start))
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
                // Each ring wobbles: a few slow waves around it, bigger and shifted further out.
                var ring = Path()
                let amp = 2 + r * 0.03
                let phase = r / spacing * 0.12
                for i in 0...240 {
                    let a = Double(i) / 240 * 2 * .pi
                    let rr = r + amp * sin(a * 4 + phase) + amp * 0.35 * sin(a * 7 - phase * 1.5)
                    let p = CGPoint(x: center.x + rr * cos(a), y: center.y + rr * sin(a))
                    if i == 0 { ring.move(to: p) } else { ring.addLine(to: p) }
                }
                ring.closeSubpath()
                ctx.stroke(ring, with: .color(Color(hex: 0x85C742).opacity(0.11)), lineWidth: 2.4)
                r += spacing
            }
        }
    }
}

/// The green play/skip button. Plays once: the triangle pushes into the bar, the bar springs back,
/// and everything settles. Only the soft glow rings keep pulsing while the app finishes loading.
struct SplashMark: View {
    let elapsed: Double
    private let green = Color(hex: 0x85C742)
    private let ink = Color(hex: 0x13200B)
    private let hit = 0.4          // when the triangle reaches the bar

    var body: some View {
        let e = max(0, elapsed - 0.15)                                   // let the logo appear first
        let d = max(0, e - hit)
        let approach = pow(min(1, e / hit), 2.2)                         // speeds up into the bar
        let spring = e < hit ? 0 : exp(-d * 6.5) * sin(d * 19)           // damped bounce after the hit
        let triX = e < hit ? -6 + 10 * approach : 1 + 3 * pow(1 - min(1, d / 0.25), 3)   // one small recoil, then still
        ZStack {
            ForEach(0..<2) { i in
                let q = (elapsed / 1.6 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                RoundedRectangle(cornerRadius: 30 + 14 * q, style: .continuous)
                    .stroke(green.opacity(0.45 * (1 - q)), lineWidth: 3)
                    .frame(width: 128 + 70 * q, height: 94 + 70 * q)
            }
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(green)
                .frame(width: 128, height: 94)
                .shadow(color: green.opacity(0.35 + 0.3 * max(0, spring)), radius: 18 + 12 * max(0, spring))
            ZStack {
                Image(systemName: "play.fill").font(.system(size: 40, weight: .black)).foregroundStyle(ink)
                    .offset(x: triX)
                RoundedRectangle(cornerRadius: 3).fill(ink)
                    .frame(width: 7, height: 42 - 7 * spring)
                    .offset(x: 24 + 3 * spring)
            }
            .frame(width: 128, height: 94)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        .scaleEffect(1 + 0.04 * max(0, spring))
    }
}
