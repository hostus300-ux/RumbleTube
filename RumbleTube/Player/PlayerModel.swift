import AVFoundation
import AVKit
import Combine
import MediaPlayer
import SwiftUI
import UIKit

/// The single app-wide player: playback, resume, quality, lock-screen controls and RumbleSkip.
/// The playback position on its own, so only the scrubber and mini-player progress redraw as it ticks.
@MainActor
final class PlayerClock: ObservableObject {
    static let shared = PlayerClock()
    @Published var time: Double = 0
}

@MainActor
final class PlayerModel: ObservableObject {
    static let shared = PlayerModel()

    @Published private(set) var item: VideoItem?
    @Published private(set) var detail: VideoDetail?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var expanded = false {
        didSet { if oldValue && !expanded { minimizedAt = Date() } }
    }
    /// When the full player was last swiped down; the mini player ignores taps briefly after this
    /// so the end of the swipe can't land on its play/pause or close button.
    private(set) var minimizedAt = Date.distantPast
    var miniPlayerArmed: Bool { Date().timeIntervalSince(minimizedAt) > 0.7 }
    @Published private(set) var stream: StreamOption?
    @Published private(set) var isPlaying = false
    /// Not @Published: it changes 4× a second, and publishing it re-drew every screen watching the player.
    /// Views that show the time observe `PlayerClock.shared` instead.
    private(set) var currentTime: Double = 0 { didSet { if PlayerClock.shared.time != currentTime { PlayerClock.shared.time = currentTime } } }
    @Published private(set) var duration: Double = 0
    /// Live streams with DVR: the part of the stream you can rewind into (player time, seconds).
    @Published private(set) var liveWindow: ClosedRange<Double>?
    /// Chapters listed in the description (3+ timestamped lines).
    @Published private(set) var chapters: [Chapter] = []
    private var pendingStart: Double?
    var currentChapter: Chapter? { Timestamps.current(chapters, at: currentTime) }
    /// Ask the full player to open the RumbleSkip panel (e.g. from the "Mark end" pill).
    @Published var openSkipPanel = false
    /// A RumbleSkip segment started on this video with no end yet.
    var pendingSkipDraft: SkipDraft? {
        guard let id = item?.id, let d = library.data.skipDrafts[id], d.end == nil else { return nil }
        return d
    }
    /// "Mark end": the end is now; open the panel to submit.
    func markSkipDraftEnd() {
        guard let id = item?.id, var d = library.data.skipDrafts[id] else { return }
        d.end = max(d.start + 0.5, currentTime)
        d.updatedAt = Date()
        library.data.skipDrafts[id] = d
        if fullscreen { fullscreen = false }
        expanded = true
        openSkipPanel = true
    }
    @Published var fullscreen = false
    @Published var zoomFill = false
    @Published private(set) var rate: Double = 1
    @Published private(set) var boosting = false
    var pip: AVPictureInPictureController?

    // RumbleSkip state
    @Published private(set) var segments: [SkipSegment] = []
    @Published private(set) var links: [YouTubeLink] = []
    @Published private(set) var skipStatus = ""
    @Published private(set) var notice: SkipSegment?
    @Published private(set) var buttonSegment: SkipSegment?
    @Published private(set) var autoMatch: AutoLinkRecord?
    private static let youtubeSession = URLSession(configuration: .ephemeral)
    private var rawSegments: [SkipSegment] = []
    private var ignored = Set<String>()
    private var skippedOnce = Set<String>()
    private var isSkipping = false

    let player = AVPlayer()
    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var itemObservers = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var lastSaved: Double = 0
    private var releaseTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var library: LibraryStore { LibraryStore.shared }

    private init() {
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] t in
            let secs = t.seconds
            Task { @MainActor in self?.tick(secs) }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = status != .paused
                // Native controls (or PiP) started playback: make sure we hold the audio for background play.
                if status == .playing, !AppAudio.ownsAudio, self.player.currentItem != nil { AppAudio.takeOver() }
                // Paused for a moment (not just buffering): hand the audio back so other apps' sound isn't held muted
                // while RumbleTube merely sits open. Pressing play takes it again.
                self.releaseTask?.cancel()
                if status == .paused, AppAudio.ownsAudio {
                    self.releaseTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        // Shorts pause the main player and take the audio: releasing it then cut the short off.
                        guard !Task.isCancelled, let self, self.player.timeControlStatus == .paused,
                              self.pip?.isPictureInPictureActive != true, !ShortsModel.anyPlayingAudibly else { return }
                        AppAudio.release()
                    }
                }
                self.updateNowPlaying()
                if self.isLive || self.audioOnly { self.updateLiveActivity() }
            }
            .store(in: &cancellables)
        setupRemoteCommands()
        PlayerCommandBridge.handler = { [weak self] c in self?.handle(c) }
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.savePosition() } }
            .store(in: &cancellables)
    }

    // MARK: - Opening videos

    /// Open a video at a given time (from a timestamp link).
    func play(_ newItem: VideoItem, at time: Double) {
        if item?.id == newItem.id, error == nil { seek(to: time); expanded = true; return }
        pendingStart = time
        play(newItem)
    }

    func play(_ newItem: VideoItem) {
        if item?.id == newItem.id, error == nil {
            expanded = true
            if !isPlaying { resume() }
            return
        }
        savePosition()
        cancelAutoplay(release: false)
        if !library.data.prefs.audioOnlySticky { audioOnlyThisVideo = false }
        upNext = nil; more = []
        viewersTask?.cancel(); liveViewers = nil
        item = newItem
        detail = nil; error = nil; loading = true; expanded = true; stream = nil
        currentTime = 0; duration = 0; artwork = nil; chapters = []
        resetSkipState()
        player.replaceCurrentItem(with: nil)
        ShortsModel.pauseAll()
        AppAudio.takeOver()

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            // Downloaded: play the saved file, no network needed.
            if let rec = DownloadManager.shared.record(newItem.id) {
                self.detail = rec.detail
                self.loadQueue(rec.detail)
                self.chapters = Timestamps.chapters(in: rec.detail.description ?? "", duration: rec.detail.duration)
                self.library.data.recordWatch(rec.item)
                let local = StreamOption(kind: .mp4, height: nil, bitrate: nil, url: DownloadManager.shared.fileURL(rec).absoluteString)
                self.start(local, at: self.pendingStart ?? self.library.data.resumePosition(for: rec.id, duration: rec.detail.duration))
                self.pendingStart = nil
                self.loading = false
                self.loadArtwork()
                await self.loadSegments()
                return
            }
            do {
                let d = try await RumbleService.shared.detail(for: newItem)
                guard !Task.isCancelled, self.item?.id == newItem.id else { return }
                self.detail = d
                self.startViewerPolling(d)
                self.updateLiveActivity()
                self.loadQueue(d)
                self.chapters = Timestamps.chapters(in: d.description ?? "", duration: d.duration)
                var hist = newItem.title == "Loading…" ? d.asItem : newItem
                if hist.thumbnail == nil { hist.thumbnail = d.thumbnail }
                if hist.duration == nil { hist.duration = d.duration.map { TimeFormat.clock($0) } }
                if hist.channelPath == nil { hist.channelPath = d.channel?.path; hist.channelName = d.channel?.name }
                self.item = hist
                self.library.data.recordWatch(hist)
                if var s = self.preferredStream(for: d) {
                    let resume = d.liveStatus == .isLive ? nil : (self.pendingStart ?? self.library.data.resumePosition(for: d.id, duration: d.duration))
                    self.pendingStart = nil
                    if d.liveStatus == .isLive, let dvr = await Self.dvrVariant(of: s) { s = dvr }   // rewindable live
                    guard !Task.isCancelled, self.item?.id == newItem.id else { return }
                    self.start(s, at: resume)
                }
                self.loading = false
                self.loadArtwork()
                await self.loadSegments()
            } catch {
                guard !Task.isCancelled, self.item?.id == newItem.id else { return }
                DiagLog.shared.log("video", "\(newItem.id): \(error.localizedDescription)")
                self.error = error.localizedDescription
                self.loading = false
            }
        }
    }

    func retry() {
        guard let item else { return }
        let it = item
        self.item = nil
        play(it)
    }

    func close() {
        WidgetBridge.activity(nil)
        cancelAutoplay(release: false)
        viewersTask?.cancel(); liveViewers = nil
        savePosition()
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil; detail = nil; error = nil; expanded = false; stream = nil; fullscreen = false; boosting = false
        pip = nil
        resetSkipState()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        AppAudio.release()
    }

    func togglePlay() { isPlaying ? player.pause() : resume() }

    /// Start/continue playback, taking the audio back if it was handed off.
    func resume() {
        guard player.currentItem != nil else { return }
        ShortsModel.pauseAll()
        AppAudio.takeOver()
        player.play()
    }

    func seek(to t: Double, precise: Bool = false) {
        let target = CMTime(seconds: max(0, t), preferredTimescale: 600)
        if precise {
            // Exact seek: a default (keyframe) seek can snap back to almost where you were, which made
            // repeated double-tap rewinds look like they did nothing.
            player.seek(to: target, toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
                        toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
        } else {
            player.seek(to: target)
        }
        currentTime = max(0, t)
    }

    // MARK: - Streams

    /// Audio only for just this video (when "carry over" is off in Settings).
    @Published private var audioOnlyThisVideo = false
    var audioOnly: Bool { library.data.prefs.audioOnlySticky ? library.data.prefs.audioOnly : audioOnlyThisVideo }

    /// Audio-only: smallest stream / lowest HLS variant and no picture; switch back restores quality.
    func setAudioOnly(_ on: Bool) {
        if library.data.prefs.audioOnlySticky { library.data.prefs.audioOnly = on } else { audioOnlyThisVideo = on }
        defer { updateLiveActivity() }
        if let pi = player.currentItem { pi.preferredPeakBitRate = on ? 1 : 0 }
        if let d = detail, stream?.kind == .mp4, !(stream?.url.hasPrefix("file:") ?? false),
           let s = preferredStream(for: d), s != stream {
            let wasPlaying = isPlaying
            start(s, at: currentTime > 1 ? currentTime : nil, autoplay: wasPlaying)
        }
        objectWillChange.send()
    }

    private func preferredStream(for d: VideoDetail) -> StreamOption? {
        if audioOnly, d.liveStatus != .isLive {
            let mp4 = d.streams.filter { $0.kind == .mp4 }
            if let small = mp4.min(by: { ($0.height ?? 0) < ($1.height ?? 0) }) { return small }
        }
        guard let want = library.data.preferredHeight, d.liveStatus != .isLive else { return d.defaultStream }
        let mp4 = d.streams.filter { $0.kind == .mp4 && ($0.height ?? 0) <= want }
        return mp4.max { ($0.height ?? 0) < ($1.height ?? 0) } ?? d.defaultStream
    }

    func select(_ s: StreamOption) {
        guard s != stream else { return }
        if s.kind == .mp4 { library.data.preferredHeight = s.height } else { library.data.preferredHeight = nil }
        let wasPlaying = isPlaying
        start(s, at: currentTime > 1 ? currentTime : nil, autoplay: wasPlaying || currentTime < 1)
    }

    private func start(_ s: StreamOption, at resume: Double?, autoplay: Bool = true) {
        guard let url = URL(string: s.url) else { return }
        stream = s
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": RumbleHTTP.userAgent, "Referer": "https://rumble.com/"],
        ])
        let pi = AVPlayerItem(asset: asset)
        pi.preferredForwardBufferDuration = 10
        if audioOnly { pi.preferredPeakBitRate = 1 }      // HLS: lowest variant
        itemObservers.removeAll()
        pi.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak pi] status in
                guard let self, let pi else { return }
                if status == .readyToPlay {
                    let d = pi.duration.seconds
                    self.duration = d.isFinite ? d : (self.detail?.duration ?? 0)
                    self.resolveSegments()
                    self.updateNowPlaying()
                } else if status == .failed {
                    self.error = pi.error?.localizedDescription ?? "Playback failed"
                    DiagLog.shared.log("player", "\(self.item?.id ?? "?") \(self.stream?.label ?? ""): \(self.error ?? "")")
                }
            }
            .store(in: &itemObservers)
        player.replaceCurrentItem(with: pi)
        if let t = resume, t > 0 {
            pi.seek(to: CMTime(seconds: t, preferredTimescale: 600), completionHandler: nil)
            currentTime = t
        }
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: pi)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.videoEnded()   // autoplay countdown, or release audio so other apps resume
            }
            .store(in: &itemObservers)
        rate = library.data.prefs.defaultRate
        player.defaultRate = Float(rate)
        if autoplay { self.resume() }
    }

    // MARK: - Gestures & speed

    func seek(by delta: Double) {
        // Repeated taps stack from where the last tap aimed, not from a position the seek hasn't reached yet.
        let base = (Date().timeIntervalSince(lastRelativeSeek) < 1.2 ? lastRelativeTarget : nil) ?? player.currentTime().seconds
        var t = base + delta
        if isLive {
            guard let w = liveWindow else { return }
            t = min(max(t, w.lowerBound + 1), w.upperBound)
        } else {
            t = max(0, duration > 0 ? min(t, duration - 0.5) : t)
        }
        lastRelativeTarget = t
        lastRelativeSeek = Date()
        seek(to: t, precise: true)
    }
    private var lastRelativeTarget: Double?
    private var lastRelativeSeek = Date.distantPast

    // MARK: - Live DVR

    var isLive: Bool { detail?.liveStatus == .isLive }
    /// Seconds behind the live edge.
    var behindLive: Double { liveWindow.map { max(0, $0.upperBound - currentTime) } ?? 0 }
    var atLiveEdge: Bool { liveWindow == nil || behindLive < 20 }

    /// Jump back to the newest part of the stream.
    func goLive() {
        guard let pi = player.currentItem else { return }
        if let w = liveWindow {
            pi.seek(to: CMTime(seconds: w.upperBound, preferredTimescale: 600), completionHandler: nil)
        } else {
            pi.seek(to: .positiveInfinity, completionHandler: nil)
        }
        if !isPlaying { resume() }
    }

    private func updateLiveWindow() {
        guard isLive, let r = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else {
            if liveWindow != nil { liveWindow = nil }
            return
        }
        let lo = r.start.seconds, hi = (r.start + r.duration).seconds
        guard lo.isFinite, hi.isFinite, hi - lo > 30 else { if liveWindow != nil { liveWindow = nil }; return }
        // only publish meaningful changes (the edge moves every tick)
        if let w = liveWindow, abs(w.lowerBound - lo) < 1, abs(w.upperBound - hi) < 1 { return }
        liveWindow = lo...hi
    }

    /// Rumble serves a rewindable copy of live streams at /live-hls-dvr/; use it when it answers.
    static func dvrVariant(of s: StreamOption) async -> StreamOption? {
        guard s.kind == .hls, s.url.contains("/live-hls/"),
              let url = URL(string: s.url.replacingOccurrences(of: "/live-hls/", with: "/live-hls-dvr/")) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 4)
        r.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        guard let res = try? await RumbleHTTP.session.data(for: r),
              (res.1 as? HTTPURLResponse)?.statusCode == 200,
              String(decoding: res.0.prefix(16), as: UTF8.self).hasPrefix("#EXTM3U") else { return nil }
        var dvr = s
        dvr.url = url.absoluteString
        return dvr
    }

    func setRate(_ r: Double) {
        rate = r
        library.data.prefs.defaultRate = r
        player.defaultRate = Float(r)
        if isPlaying, !boosting { player.rate = Float(r) }
    }

    func startBoost() {
        guard player.currentItem != nil, detail?.liveStatus != .isLive else { return }
        if !isPlaying { resume() }
        boosting = true
        player.rate = Float(library.data.prefs.boostRate)
    }

    func endBoost() {
        guard boosting else { return }
        boosting = false
        if player.rate != 0 { player.rate = Float(rate) }
    }

    /// Skip the RumbleSkip segment under the playhead (any category that isn't ignored).
    func skipCurrentSegment() {
        let t = player.currentTime().seconds
        if let seg = segments.first(where: { t >= $0.start && t < $0.end && library.data.skip.action(for: $0.category) != .off }) {
            skip(seg)
        } else {
            seek(by: Double(library.data.prefs.seekSeconds))
        }
    }

    func perform(_ action: GestureAction) {
        let secs = Double(library.data.prefs.seekSeconds)
        switch action {
        case .none, .speedBoost: break
        case .seekBack: seek(by: -secs)
        case .seekForward: seek(by: secs)
        case .playPause: togglePlay()
        case .fullscreen: fullscreen.toggle()
        case .minimize: if fullscreen { fullscreen = false } else { expanded = false }
        case .close: fullscreen = false; close()
        case .skipSegment: skipCurrentSegment()
        case .toggleZoom: zoomFill.toggle()
        }
    }

    // MARK: - Time & skipping

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        updateLiveWindow()
        checkSkip()
        if abs(t - lastSaved) > 15 { lastSaved = t; savePosition() }
        if (isLive || audioOnly), Date().timeIntervalSince(lastActivityUpdate) > 15 { updateLiveActivity() }
    }

    private var lastActivityUpdate = Date.distantPast

    /// Lock Screen / Dynamic Island card while a live stream or an audio-only video plays.
    func updateLiveActivity() {
        lastActivityUpdate = Date()
        guard item != nil, isLive || audioOnly else { WidgetBridge.activity(nil); return }
        WidgetBridge.activity(.init(title: detail?.title ?? item?.title, channel: detail?.channel?.name ?? item?.channelName,
                                    viewers: liveViewers ?? item?.watching, behindLive: behindLive, playing: isPlaying, isLive: isLive,
                                    audioOnly: audioOnly, position: currentTime, duration: duration))
    }

    /// Buttons on the Live Activity.
    func handle(_ c: PlayerCommandBridge.Command) {
        switch c {
        case .skip(let s): seek(by: s)
        case .togglePlay: togglePlay()
        case .goLive: goLive()
        }
        Task { try? await Task.sleep(nanoseconds: 400_000_000); self.updateLiveActivity() }
    }

    // MARK: - Live viewer count

    /// People watching right now (live streams), refreshed every 30 s.
    @Published private(set) var liveViewers: Int?
    private var viewersTask: Task<Void, Never>?

    private func startViewerPolling(_ d: VideoDetail) {
        viewersTask?.cancel()
        liveViewers = item?.watching
        guard d.liveStatus == .isLive, let vid = d.chatID ?? item?.numericID else { return }
        let id = d.id
        viewersTask = Task { [weak self] in
            while !Task.isCancelled {
                var r = LiveViewers.request(videoID: vid)
                r.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
                if let res = try? await RumbleHTTP.session.data(for: r), let v = LiveViewers.parse(res.0) {
                    guard let self, self.item?.id == id else { return }
                    if let n = v.viewers { self.liveViewers = n; self.item?.watching = n }
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    // MARK: - Autoplay

    /// The next video (first unwatched recommendation), shown in the player and played at the end when autoplay is on.
    @Published var upNext: VideoItem?
    /// More from this video's channel (the recommendation queue).
    @Published private(set) var more: [VideoItem] = []

    private func loadQueue(_ d: VideoDetail) {
        guard let path = d.channel?.path else { more = []; upNext = nil; return }
        let id = d.id
        Task {
            guard let page = try? await RumbleService.shared.channel(path), self.item?.id == id else { return }
            self.more = page.items
            self.setQueue(page.items)
        }
    }
    /// Seconds left before autoplay starts the next video; nil when no countdown is running.
    @Published private(set) var autoplayCountdown: Int?
    private var autoplayTask: Task<Void, Never>?
    var autoplayOn: Bool { library.data.prefs.autoplay }

    func setAutoplay(_ on: Bool) {
        library.data.prefs.autoplay = on
        if !on { cancelAutoplay() }
        objectWillChange.send()
    }

    func setQueue(_ more: [VideoItem]) {
        let lib = library.data
        upNext = more.first { $0.id != item?.id && !$0.isLive && $0.isShort != true && (lib.watchFraction(for: $0) ?? 0) < 0.9 && lib.muteEntry(for: $0) == nil }
    }

    private func videoEnded() {
        savePosition()
        guard autoplayOn, !isLive, let next = upNext, next.id != item?.id else { AppAudio.release(); return }
        autoplayTask?.cancel()
        autoplayCountdown = 8
        autoplayTask = Task { [weak self] in
            while let n = self?.autoplayCountdown, n > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.autoplayCountdown = n - 1
            }
            guard !Task.isCancelled else { return }
            self?.playUpNext()
        }
    }

    func cancelAutoplay(release: Bool = true) {
        autoplayTask?.cancel(); autoplayTask = nil
        if autoplayCountdown != nil { autoplayCountdown = nil; if release { AppAudio.release() } }
    }

    func playUpNext() {
        autoplayTask?.cancel(); autoplayTask = nil
        autoplayCountdown = nil
        guard let next = upNext else { return }
        let wasExpanded = expanded
        play(next)
        if !wasExpanded { expanded = false }      // keep it in the mini player if that's where you were
    }

    private func checkSkip() {
        guard !segments.isEmpty, !isSkipping, player.currentItem?.status == .readyToPlay else {
            if buttonSegment != nil { buttonSegment = nil }
            return
        }
        let t = player.currentTime().seconds
        if let hit = SkipEngine.active(segments, at: t, settings: library.data.skip, ignored: ignored) {
            if hit.1 == .skip { skip(hit.0, auto: true) }
            else if buttonSegment?.uuid != hit.0.uuid { buttonSegment = hit.0 }
        } else if buttonSegment != nil {
            buttonSegment = nil
        }
    }

    func skip(_ seg: SkipSegment, auto: Bool = false) {
        let end = duration > 0 ? min(seg.end, duration - 0.05) : seg.end
        let saved = max(0, end - currentTime)
        isSkipping = true
        buttonSegment = nil
        player.seek(to: CMTime(seconds: end, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.3, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.isSkipping = false }
        }
        if skippedOnce.insert(seg.uuid).inserted {
            library.data.skipStats.skips += 1
            library.data.skipStats.secondsSaved += saved
            if seg.source == .server {
                let client = SkipClient(settings: library.data.skip)
                Task { await client.reportViewed(uuid: seg.uuid) }
            }
        }
        if library.data.skip.showNotice { showNotice(seg) }
    }

    func unskip(_ seg: SkipSegment) {
        ignored.insert(seg.uuid)
        notice = nil
        seek(to: seg.start)
        rebuildBoundaryObserver()
    }

    func jump(to seg: SkipSegment) {
        ignored.insert(seg.uuid)
        seek(to: seg.start)
        rebuildBoundaryObserver()
        resume()
    }

    private func showNotice(_ seg: SkipSegment) {
        notice = seg
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func dismissNotice() { notice = nil }

    private func resetSkipState() {
        segments = []; rawSegments = []; links = []; ignored = []; skippedOnce = []; autoMatch = nil
        notice = nil; buttonSegment = nil; skipStatus = ""
        rebuildBoundaryObserver()
    }

    private func resolveSegments() {
        let d = duration > 0 ? duration : detail?.duration
        segments = SkipEngine.resolve(rawSegments, videoDuration: d)
        rebuildBoundaryObserver()
        let n = segments.count
        if !skipStatus.contains("unreachable") {
            skipStatus = n == 0 ? "No segments yet" : "\(n) segment\(n == 1 ? "" : "s")"
        }
    }

    /// Fires exactly at auto-skip segment starts so skips are frame-accurate between periodic ticks.
    private func rebuildBoundaryObserver() {
        if let o = boundaryObserver { player.removeTimeObserver(o); boundaryObserver = nil }
        let starts = SkipEngine.autoSkipStarts(segments, settings: library.data.skip, ignored: ignored)
        guard !starts.isEmpty else { return }
        let times = starts.map { NSValue(time: CMTime(seconds: $0 + 0.05, preferredTimescale: 600)) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            Task { @MainActor in self?.checkSkip() }
        }
    }

    func settingsChanged() {
        resolveSegments()
        Task { await loadSegments() }
    }

    // MARK: - RumbleSkip data

    func loadSegments() async {
        guard let vid = item?.id else { return }
        let settings = library.data.skip
        let client = SkipClient(settings: settings)
        skipStatus = "Loading…"
        var errors: [String] = []
        var segs = library.data.localSegments[vid] ?? []
        var fetchedLinks: [YouTubeLink] = []

        if settings.server != nil {
            do {
                let (s, l) = try await client.fetchServer(videoID: vid)
                segs += s; fetchedLinks = l
            } catch { errors.append("server unreachable") }
        }
        if let local = library.data.localLinks[vid], !fetchedLinks.contains(where: { $0.youtubeID == local.youtubeID }) {
            fetchedLinks.insert(local, at: 0)
        }
        var auto: AutoLinkRecord?
        if settings.useYouTubeLinks, let link = fetchedLinks.first {
            do { segs += try await client.fetchSponsorBlock(youtubeID: link.youtubeID, offset: link.offset) }
            catch { errors.append("SponsorBlock unreachable") }
        } else if settings.useYouTubeLinks, settings.autoMatchYouTube, let d = detail, d.liveStatus != .isLive {
            // Nobody has linked this video yet: look for its YouTube upload ourselves.
            skipStatus = "Looking for this video on YouTube…"
            let (rec, isNew) = await findYouTubeCopy(for: vid, detail: d)
            auto = rec
            if !rec.rejected, rec.confidence.usable, let yt = rec.youtubeID {
                do {
                    var ytSegs = try await client.fetchSponsorBlock(youtubeID: yt, offset: 0)
                    if rec.confidence == .likely { ytSegs = ytSegs.map { var s = $0; s.needsConfirm = true; return s } }
                    segs += ytSegs
                } catch { errors.append("SponsorBlock unreachable") }
                // Share confident matches so other users skip the search.
                if isNew, rec.confidence == .exact, settings.server != nil {
                    try? await client.shareLink(videoID: vid, youtubeID: yt, offset: 0)
                }
            }
        }
        guard item?.id == vid else { return }
        autoMatch = auto
        rawSegments = segs
        links = fetchedLinks
        skipStatus = ""
        resolveSegments()
        if !errors.isEmpty { skipStatus += " (\(errors.joined(separator: ", ")))" }
    }

    /// Cached YouTube search → match record (searches at most once per video, re-checks misses after a few days).
    private func findYouTubeCopy(for vid: String, detail d: VideoDetail) async -> (AutoLinkRecord, Bool) {
        if let cached = library.data.autoLinks[vid], cached.isFresh() { return (cached, false) }
        let req = YouTubeMatcher.searchRequest(YouTubeMatcher.query(title: d.title, channel: d.channel?.name))
        guard let r = try? await Self.youtubeSession.data(for: req),
              (r.1 as? HTTPURLResponse)?.statusCode == 200 else {
            return (AutoLinkRecord(confidence: .none, checkedAt: .distantPast), false)   // network trouble: try again next time
        }
        let candidates = YouTubeMatcher.parseSearch(String(decoding: r.0, as: UTF8.self))
        let duration = d.duration ?? (self.duration > 0 ? self.duration : nil)
        let match = YouTubeMatcher.bestMatch(title: d.title, channel: d.channel?.name, duration: duration, candidates: candidates)
        let rec = AutoLinkRecord.from(match, rumbleDuration: duration)
        library.data.saveAutoLink(vid, rec)
        return (rec, true)
    }

    /// "Not this video": stop using the automatic match.
    func rejectAutoMatch() async {
        guard let vid = item?.id, var rec = library.data.autoLinks[vid] else { return }
        rec.rejected = true
        library.data.saveAutoLink(vid, rec)
        await loadSegments()
    }

    /// Different edit on YouTube: the user says where Rumble's extra time is, which fixes the offset.
    func alignAutoMatch(extraAtStart: Bool) async -> String {
        guard let rec = autoMatch, let yt = rec.youtubeID else { return "" }
        let offset = extraAtStart ? (rec.lengthDifference ?? 0) : 0
        return await linkYouTube(yt, offset: offset)
    }

    /// Submit to the community server, or save on this device. Returns a message for the user.
    func submitSegment(start: Double, end: Double, category: SkipCategory, localOnly: Bool) async -> String {
        guard let vid = item?.id else { return "No video" }
        let vd = duration > 0 ? duration : (detail?.duration ?? 0)
        guard end > start, end - start >= 0.5 else { return "Set a start and an end first (at least 0.5s)." }
        let e = vd > 0 ? min(end, vd) : end
        let settings = library.data.skip
        if !localOnly, settings.server != nil {
            do {
                let r = try await SkipClient(settings: settings)
                    .submit(videoID: vid, videoDuration: vd, start: start, end: e, category: category)
                await loadSegments()
                return r.duplicate ? "Someone already marked that — counted as an upvote." : "Submitted. Thanks!"
            } catch {
                return "Submit failed: \(error.localizedDescription)"
            }
        }
        let seg = SkipSegment(uuid: "local-" + SkipSettings.randomID().prefix(10), start: start, end: e,
                              category: category, source: .local, votes: 0, videoDuration: vd)
        library.data.localSegments[vid, default: []].append(seg)
        await loadSegments()
        return "Saved on this device."
    }

    func vote(_ seg: SkipSegment, up: Bool) async -> String {
        guard let vid = item?.id else { return "" }
        switch seg.source {
        case .local:
            library.data.localSegments[vid]?.removeAll { $0.uuid == seg.uuid }
            await loadSegments()
            return "Removed."
        case .youtube:
            return "Vote on YouTube-linked segments in SponsorBlock itself."
        case .server:
            do {
                let removed = try await SkipClient(settings: library.data.skip).vote(uuid: seg.uuid, type: up ? 1 : -1)
                if !up { ignored.insert(seg.uuid) }
                await loadSegments()
                return removed ? "Your segment was removed." : (up ? "Upvoted." : "Downvoted.")
            } catch {
                return "Vote failed: \(error.localizedDescription)"
            }
        }
    }

    func linkYouTube(_ input: String, offset: Double) async -> String {
        guard let vid = item?.id else { return "" }
        guard let yt = SkipEngine.parseYouTubeID(input) else { return "Paste a YouTube link or 11-character video ID." }
        let settings = library.data.skip
        let client = SkipClient(settings: settings)
        let count = (try? await client.fetchSponsorBlock(youtubeID: yt, offset: offset).count) ?? 0
        library.data.localLinks[vid] = YouTubeLink(uuid: "local-link", youtubeID: yt, offset: offset, votes: 0, local: true)
        if settings.server != nil { try? await client.shareLink(videoID: vid, youtubeID: yt, offset: offset) }
        await loadSegments()
        return count > 0 ? "Linked — \(count) SponsorBlock segment\(count == 1 ? "" : "s") found."
                         : "Linked, but SponsorBlock has no segments for that video yet."
    }

    func unlinkYouTube() async {
        guard let vid = item?.id else { return }
        library.data.localLinks[vid] = nil
        await loadSegments()
    }

    // MARK: - Persistence

    func savePosition() {
        guard let id = item?.id, detail?.liveStatus != .isLive, currentTime > 0 else { return }
        library.data.savePosition(id, currentTime)
    }

    // MARK: - Lock screen / Control Center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.togglePlay() }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.seek(to: self.currentTime + 15) }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.seek(to: self.currentTime - 15) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self.seek(to: t) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let item else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: detail?.title ?? item.title,
            MPMediaItemPropertyArtist: detail?.channel?.name ?? item.channelName ?? "Rumble",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate),
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if detail?.liveStatus == .isLive { info[MPNowPlayingInfoPropertyIsLiveStream] = true }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork() {
        guard let s = detail?.thumbnail ?? item?.thumbnail, let url = URL(string: s) else { return }
        let id = item?.id
        Task { [weak self] in
            guard let r = try? await URLSession.shared.data(from: url), let img = UIImage(data: r.0) else { return }
            guard let self, self.item?.id == id else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            self.updateNowPlaying()
        }
    }
}
