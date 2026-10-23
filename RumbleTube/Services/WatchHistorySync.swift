import Foundation

/// Pulls your Rumble watch history (Continue Watching + Watch History, with how far you got) into the app's
/// one history list, so resume points, progress bars and For You all use it.
@MainActor
final class WatchHistorySync: ObservableObject {
    static let shared = WatchHistorySync()
    @Published private(set) var syncing = false
    private var lastSync: Date?

    func sync(force: Bool = false) async {
        guard AccountStore.shared.loggedIn, !syncing else { return }
        if !force, let t = lastSync, Date().timeIntervalSince(t) < 10 * 60 { return }
        syncing = true
        defer { syncing = false }
        let svc = RumbleService.shared
        // First pass, in parallel: Watch History (true most-recent order, includes finished videos)
        // and the first page of Continue Watching. Merge right away so the app fills in within a second or two.
        async let historyPage = try? svc.listing("/playlists/watch-history", allowWebView: false)
        async let firstCW = try? svc.followingFeed(pill: "continue-watching", offset: 0, limit: 24)
        let h = await historyPage, f1 = await firstCW
        let first = (h?.items ?? []) + (f1?.items ?? [])
        merge(first)
        // Then the rest of Continue Watching in the background of this task.
        var offset = f1?.raw.count ?? 0
        var more = (f1?.hasMore ?? false) && !(f1?.raw.isEmpty ?? true)
        var rest: [VideoItem] = []
        for _ in 0..<4 where more {
            guard let f = try? await svc.followingFeed(pill: "continue-watching", offset: offset, limit: 24) else { break }
            rest += f.items
            offset += f.raw.count
            more = f.hasMore && !f.raw.isEmpty
        }
        // Merge the whole list again so older videos are dated after the ones already placed.
        if !rest.isEmpty { merge(first + rest) }
        lastSync = Date()
    }

    private func merge(_ items: [VideoItem]) {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { return }
        LibraryStore.shared.data.mergeRemoteHistory(unique)
    }
}
