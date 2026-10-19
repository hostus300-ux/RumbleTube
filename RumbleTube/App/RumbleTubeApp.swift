import SwiftUI

@main
struct RumbleTubeApp: App {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerModel.shared
    @StateObject private var router = Router()
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
                .tint(.rumbleGreen)
                .onOpenURL { router.handle($0) }
        }
        .onChange(of: phase) { p in
            if p != .active { player.savePosition(); library.saveNow() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var router: Router
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        TabView(selection: $router.tab) {
            tab(.home, "Home", "house") { HomeView() }
            tab(.explore, "Explore", "safari") { ExploreView() }
            tab(.search, "Search", "magnifyingglass") { SearchView() }
            tab(.library, "Library", "books.vertical") { LibraryView() }
            tab(.settings, "Settings", "gearshape") { SettingsView() }
        }
        .sheet(isPresented: $player.expanded) {
            PlayerScreen()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(router)
                .tint(.rumbleGreen)
        }
    }

    private func tab<V: View>(_ t: Router.Tab, _ title: String, _ icon: String, @ViewBuilder _ content: () -> V) -> some View {
        NavigationStack(path: router.path(t)) {
            content()
                .navigationDestination(for: ChannelRef.self) { ChannelView(channel: $0) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() }
        .tabItem { Label(title, systemImage: icon) }
        .tag(t)
    }
}
