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
        var remote: [VideoItem] = []
        // Continue Watching pages through everything you've started (newest first), with progress.
        var offset = 0
        for _ in 0..<5 {
            guard let f = try? await RumbleService.shared.followingFeed(pill: "continue-watching", offset: offset, limit: 24) else { break }
            remote += f.items
            offset += f.raw.count
            if !f.hasMore || f.raw.isEmpty { break }
        }
        // Watch History (latest 10, includes finished videos and their % watched).
        if let h = try? await RumbleService.shared.listing("/playlists/watch-history", allowWebView: false) {
            // Watch History is the true "most recently watched" order, so it goes first.
            remote = h.items + remote
        }
        var seen = Set<String>()
        remote = remote.filter { seen.insert($0.id).inserted }
        guard !remote.isEmpty else { return }
        LibraryStore.shared.data.mergeRemoteHistory(remote)
        lastSync = Date()
    }
}
