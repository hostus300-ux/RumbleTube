import UIKit
import BackgroundTasks
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppAudio.browsing()   // never interrupt the user's music/podcasts just by opening the app
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AccountStore.refreshTaskID, using: nil) { task in
            let work = Task { @MainActor in
                await AccountStore.shared.backgroundCheck()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in DownloadManager.shared.backgroundCompletion = completionHandler }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            PlayerModel.shared.expanded = false
            if let path = info["channelPath"] as? String {
                Router.shared.open(ChannelRef(path: path, name: info["channelName"] as? String ?? ""))
            } else {
                Router.shared.showInbox()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct RumbleTubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerModel.shared
    @StateObject private var router = Router.shared
    @StateObject private var account = AccountStore.shared
    @Environment(\.scenePhase) private var phase

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(router)
                .environmentObject(account)
                .onOpenURL { router.handle($0) }
        }
        .onChange(of: phase) { p in
            if p == .active { account.startPolling() }
            else {
                ShortsModel.pauseAll()
                player.savePosition(); library.saveNow()
                WidgetBridge.update(force: true)
                if account.alertsEnabled || library.data.prefs.liveAlerts { AccountStore.scheduleRefresh() }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var router: Router
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var account: AccountStore
    /// Not observed here: Shorts publishes progress several times a second, which would redraw the whole app.
    private let shorts = ShortsModel.shared
    /// Only flips when you change scroll direction, so redrawing the tab bar then is cheap.
    @ObservedObject private var tabBar = TabBarState.shared
    @StateObject private var gate = LaunchGate()
    @State private var splashGone = false
    /// Your Rumble profile picture, drawn as a small circle for the "Me" tab.
    @State private var meIcon: UIImage?

    private var prefs: AppPreferences { library.data.prefs }
    /// The app draws its own tab bar (so it can shrink like Rumble's), so the mini player always floats above it.
    private var useAccessory: Bool { false }
    private var scheme: ColorScheme? { prefs.theme == .system ? nil : (prefs.theme == .dark ? .dark : .light) }

    var body: some View {
        let tabs = prefs.visibleTabs
        TabView(selection: $router.tab) {
            ForEach(tabs) { t in
                tab(t)
            }
        }
        .environmentObject(shorts)
        .background(alignment: .bottomLeading) { PiPHost() }
        // Rumble-style tab bar: full with labels, slimming to an icons-only pill while you scroll down.
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                if router.tab != .shorts { MiniPlayer() }
                RumbleTabBar(tabs: tabs, selection: $router.tab, meIcon: meIcon,
                             compact: prefs.minimizeTabBar && tabBar.compact) { t in
                    router.paths[t] = NavigationPath()      // tap the current tab again: back to its first page
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)   // stays put (behind the keyboard) while typing
        }
        .overlay {
            if !splashGone {
                SplashView(reveal: gate.ready)
                    .animation(.easeOut(duration: 0.35), value: gate.ready)
            }
        }
        .task { await gate.run() }
        .task(id: account.avatarURL) {
            guard let url = account.avatarURL, let img = await AvatarCache.shared.load(url) else { meIcon = nil; return }
            meIcon = Self.circle(img, side: 28)
        }
        .onChange(of: gate.ready) { r in
            guard r else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { splashGone = true }
        }
        .tint(Color(hex: prefs.accent.hex))
        .preferredColorScheme(scheme)
        .id(prefs.accent)   // rebuild so every accent-coloured view picks up a new accent
        .onAppear {
            Theme.accentHex = prefs.accent.hex
            if !tabs.contains(router.tab) { router.tab = tabs.first ?? .account }
            openLaunchScreen()
        }
        .onChange(of: prefs.accent) { a in Theme.accentHex = a.hex }
        .onChange(of: tabs) { t in if !t.contains(router.tab) { router.tab = t.first ?? .account } }
        .onChange(of: router.tab) { t in
            updateShorts(tab: t, expanded: player.expanded, minimizing: false)
            TabBarState.shared.setCompact(false)      // a new tab starts with the full bar
        }
        .onChange(of: player.expanded) { e in updateShorts(tab: router.tab, expanded: e, minimizing: !e) }
        .muteSheetHost(active: !player.expanded)
        .tagSheetHost(active: !player.expanded)
        .sheet(isPresented: $player.expanded) {
            PlayerScreen()
                .muteSheetHost(active: true)
                .tagSheetHost(active: true)
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(router)
                .environmentObject(account)
                .environmentObject(shorts)
                .tint(Color(hex: prefs.accent.hex))
                .preferredColorScheme(scheme)
        }
    }

    static func circle(_ img: UIImage, side: CGFloat) -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return r.image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
            let k = max(side / img.size.width, side / img.size.height)
            let w = img.size.width * k, h = img.size.height * k
            img.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// `-launchTab <tab or screen>` (used by the CI simulator check to screenshot each screen).
    private func openLaunchScreen() {
        guard let want = UserDefaults.standard.string(forKey: "launchTab") else { return }
        if let t = AppTab(rawValue: want) { router.tab = t; return }
        let routes: [String: AppRoute] = ["search": .search, "inbox": .inbox, "settings": .settings, "create": .create]
        if let r = routes[want] {
            router.tab = .home
            var p = NavigationPath(); p.append(r); router.paths[.home] = p
        }
    }

    /// Shorts play only while their tab is in front. Minimizing a video while on the Shorts tab must not start a
    /// Short (that paused the video): Shorts wait until you switch tabs or the video stops.
    private func updateShorts(tab: AppTab, expanded: Bool, minimizing: Bool) {
        let videoPlaying = player.item != nil && player.isPlaying
        if tab == .shorts && !expanded && !(minimizing && videoPlaying) { shorts.activate() } else { shorts.deactivate() }
    }

    @ViewBuilder private func content(_ t: AppTab) -> some View {
        switch t {
        case .home: HomeScreen()
        case .shorts: ShortsView()
        case .discover: DiscoverScreen()
        case .myFeed: MyFeedScreen()
        case .account: AccountScreen()
        }
    }

    private func tab(_ t: AppTab) -> some View {
        NavigationStack(path: router.path(t)) {
            content(t)
                .navigationDestination(for: ChannelRef.self) { ChannelView(channel: $0).miniPlayerSpace() }
                .navigationDestination(for: CommentTarget.self) { CommentsScreen(target: $0).miniPlayerSpace() }
                .navigationDestination(for: AppRoute.self) { $0.screen }
        }
        .toolbar(.hidden, for: .tabBar)
        // Room for the app's own tab bar (fixed, so pages don't jump when it slims down).
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: RumbleTabBar.reservedHeight) }
        .tag(t)
    }
}


/// The app's tab bar, drawn like Rumble's: icons with labels, shrinking to a slim icons-only pill while you
/// scroll down and growing back as soon as you scroll up.
struct RumbleTabBar: View {
    static let reservedHeight: CGFloat = 64
    let tabs: [AppTab]
    @Binding var selection: AppTab
    let meIcon: UIImage?
    let compact: Bool
    var onReselect: (AppTab) -> Void = { _ in }

    var body: some View {
        HStack(spacing: compact ? 2 : 0) {
            ForEach(tabs) { t in
                Button {
                    if selection == t { onReselect(t) } else { selection = t }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: { item(t) }
                .buttonStyle(.plain)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(selection == t ? .isSelected : [])
            }
        }
        .padding(.horizontal, compact ? 8 : 6)
        .padding(.vertical, compact ? 5 : 6)
        .background { barBackground }
        .padding(.horizontal, compact ? 0 : 14)
        .frame(maxWidth: compact ? nil : .infinity)
        .padding(.bottom, 2)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: compact)
        .animation(.easeInOut(duration: 0.15), value: selection)
    }

    @ViewBuilder private var barBackground: some View {
        if GlassUI.enabled {
            Capsule().fill(.clear).glassCapsule(interactive: false)
        } else {
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        }
    }

    private func item(_ t: AppTab) -> some View {
        let on = selection == t
        return VStack(spacing: 2) {
            icon(t).frame(width: compact ? 24 : 24, height: 24)
            if !compact {
                Text(t.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .foregroundStyle(on ? Color.accentColor : Color.primary)
        .frame(width: compact ? 46 : nil, height: compact ? 38 : 48)
        .frame(maxWidth: compact ? nil : .infinity)
        .background {
            if on { Capsule().fill(Color.primary.opacity(0.1)) }
        }
        .contentShape(Capsule())
    }

    @ViewBuilder private func icon(_ t: AppTab) -> some View {
        if t == .account, let img = meIcon {
            Image(uiImage: img).resizable().scaledToFill().frame(width: 24, height: 24).clipShape(Circle())
        } else {
            t.image.resizable().scaledToFit().frame(width: 22, height: 22)
        }
    }
}
