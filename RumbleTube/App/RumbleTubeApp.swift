import BackgroundTasks
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
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

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            PlayerModel.shared.expanded = false
            Router.shared.tab = .inbox
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
                .tint(.rumbleGreen)
                .onOpenURL { router.handle($0) }
        }
        .onChange(of: phase) { p in
            if p == .active { account.startPolling() }
            else {
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

    var body: some View {
        TabView(selection: $router.tab) {
            tab(.home, "Home", "house") { HomeView() }
            tab(.explore, "Explore", "safari") { ExploreView() }
            tab(.search, "Search", "magnifyingglass") { SearchView() }
            tab(.inbox, "Inbox", "bell") { InboxView() }
                .badge(account.hasUnread ? 1 : 0)
            tab(.library, "Library", "books.vertical") { LibraryView() }
        }
        .sheet(isPresented: $player.expanded) {
            PlayerScreen()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(router)
                .environmentObject(account)
                .tint(.rumbleGreen)
        }
    }

    private func tab<V: View>(_ t: Router.Tab, _ title: String, _ icon: String, @ViewBuilder _ content: () -> V) -> some View {
        NavigationStack(path: router.path(t)) {
            content()
                .navigationDestination(for: ChannelRef.self) { ChannelView(channel: $0) }
                .navigationDestination(for: CommentTarget.self) { CommentsScreen(target: $0) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() }
        .tabItem { Label(title, systemImage: icon) }
        .tag(t)
    }
}
