import Foundation
import UIKit
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Writes what the widgets show (live channels, continue watching) and drives the live-stream Live Activity.
@MainActor
enum WidgetBridge {
    private static var lastWrite = Date.distantPast

    static func update(force: Bool = false) {
        guard WidgetShared.url != nil else { return }                 // no App Group (e.g. signing stripped it)
        guard force || Date().timeIntervalSince(lastWrite) > 60 else { return }
        lastWrite = Date()
        let lib = LibraryStore.shared.data
        let live = Array(MyFeedModel.shared.channels.filter(\.isLive).prefix(4))
        let started: [(video: VideoItem, progress: Double)] = Array(lib.history.lazy.compactMap { h -> (video: VideoItem, progress: Double)? in
            let f = lib.watchFraction(for: h.video) ?? 0
            return f > 0.03 && f < 0.95 && !h.video.isLive ? (h.video, f) : nil
        }.prefix(3))
        let signedIn = AccountStore.shared.loggedIn
        Task.detached(priority: .utility) {
            var s = WidgetSnapshot()
            s.signedIn = signedIn
            for c in live {
                s.liveNow.append(.init(name: c.ref.name, path: c.ref.path, viewers: c.liveViewers,
                                       avatar: await small(c.ref.avatar, side: 60)))
            }
            for h in started {
                s.continueWatching.append(.init(id: h.video.id, title: h.video.title, channel: h.video.channelName,
                                                url: h.video.url, progress: h.progress,
                                                thumb: await small(h.video.thumbnail, side: 320)))
            }
            WidgetShared.save(s)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Small JPEG for the widget (widgets have tight memory limits).
    nonisolated private static func small(_ url: String?, side: CGFloat) async -> Data? {
        guard let url, let u = URL(string: url) else { return nil }
        let data: Data?
        if u.isFileURL { data = try? Data(contentsOf: u) }
        else { data = (try? await URLSession.shared.data(from: u))?.0 }
        guard let data, let img = UIImage(data: data) else { return nil }
        let k = side / max(img.size.width, img.size.height, 1)
        let out = k < 1 ? (await img.byPreparingThumbnail(ofSize: CGSize(width: img.size.width * k, height: img.size.height * k)) ?? img) : img
        return out.jpegData(compressionQuality: 0.7)
    }

    // MARK: Live Activity for the live stream being watched

    #if canImport(ActivityKit)
    private static var activityID: String?
    #endif

    static func liveActivity(title: String?, channel: String?, viewers: Int?, behindLive: Double, playing: Bool, active: Bool) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        let state = LiveStreamAttributes.ContentState(viewers: viewers, behindLive: Int(behindLive), isPlaying: playing)
        let current = Activity<LiveStreamAttributes>.activities.first { $0.id == activityID }
        if !active {
            if let current { Task { await current.end(nil, dismissalPolicy: .immediate) } }
            activityID = nil
            return
        }
        if let current, current.attributes.title == (title ?? "") {
            Task { await current.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))) }
        } else {
            if let current { Task { await current.end(nil, dismissalPolicy: .immediate) } }
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attrs = LiveStreamAttributes(title: title ?? "Live stream", channel: channel ?? "")
            activityID = try? Activity.request(attributes: attrs,
                                               content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))).id
        }
        #endif
    }
}
