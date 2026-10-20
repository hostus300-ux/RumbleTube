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

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            PlayerModel.shared.expanded = false
            Router.shared.showInbox()
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
                if account.alertsEnabled { AccountStore.scheduleRefresh() }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var router: Router
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var account: AccountStore
    @StateObject private var shorts = ShortsModel.shared

    private var prefs: AppPreferences { library.data.prefs }
    private var scheme: ColorScheme? { prefs.theme == .system ? nil : (prefs.theme == .dark ? .dark : .light) }

    var body: some View {
        let tabs = prefs.visibleTabs
        TabView(selection: $router.tab) {
            ForEach(tabs) { t in
                tab(t)
            }
        }
        .environmentObject(shorts)
        .minimizingTabBar()
        .tint(Color(hex: prefs.accent.hex))
        .preferredColorScheme(scheme)
        .id(prefs.accent)   // rebuild so every accent-coloured view picks up a new accent
        .onAppear {
            Theme.accentHex = prefs.accent.hex
            if !tabs.contains(router.tab) { router.tab = tabs.first ?? .account }
        }
        .onChange(of: prefs.accent) { a in Theme.accentHex = a.hex }
        .onChange(of: tabs) { t in if !t.contains(router.tab) { router.tab = t.first ?? .account } }
        .onChange(of: router.tab) { t in updateShorts(tab: t, expanded: player.expanded) }
        .onChange(of: player.expanded) { e in updateShorts(tab: router.tab, expanded: e) }
        .sheet(isPresented: $player.expanded) {
            PlayerScreen()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(router)
                .environmentObject(account)
                .environmentObject(shorts)
                .tint(Color(hex: prefs.accent.hex))
                .preferredColorScheme(scheme)
        }
    }

    private func updateShorts(tab: AppTab, expanded: Bool) {
        if tab == .shorts && !expanded { shorts.activate() } else { shorts.deactivate() }
    }

    @ViewBuilder private func content(_ t: AppTab) -> some View {
        switch t {
        case .home: HomeScreen()
        case .shorts: ShortsView()
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
        .overlay(alignment: .bottom) { if t != .shorts { MiniPlayer() } }
        .tabItem { Label(t.title, systemImage: t.icon) }
        .tag(t)
    }
}
