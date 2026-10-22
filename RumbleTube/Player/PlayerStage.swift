import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - Orientation (portrait app, landscape only for fullscreen video)

enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait

    static func set(_ newMask: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        mask = newMask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { _ in }
    }
}

// MARK: - Video layer (AVPlayerLayer + Picture in Picture)

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var fill: Bool
    var enablePiP: Bool

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        context.coordinator.view = v
        if enablePiP, AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: v.playerLayer) {
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            pip.delegate = context.coordinator
            PlayerModel.shared.pip = pip
        }
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        let g: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if v.playerLayer.videoGravity != g {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
            v.playerLayer.videoGravity = g
            CATransaction.commit()
        }
        if !context.coordinator.backgrounded, v.playerLayer.player !== player { v.playerLayer.player = player }
    }

    /// When the full player closes (mini player), let go of the layer: an off-screen layer still attached to the
    /// player makes iOS pause the video when the phone locks.
    static func dismantleUIView(_ v: PlayerLayerView, coordinator: Coordinator) {
        if !coordinator.pipActive {
            v.playerLayer.player = nil
            Task { @MainActor in
                if PlayerModel.shared.pip?.playerLayer === v.playerLayer { PlayerModel.shared.pip = nil }
            }
        }
    }

    /// Detach while backgrounded so audio keeps playing (unless PiP is showing).
    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        weak var view: PlayerLayerView?
        let player: AVPlayer
        var backgrounded = false
        var pipActive = false
        private var tokens: [NSObjectProtocol] = []

        init(player: AVPlayer) {
            self.player = player
            super.init()
            let nc = NotificationCenter.default
            tokens.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.pipActive else { return }
                self.backgrounded = true
                self.view?.playerLayer.player = nil
            })
            tokens.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.backgrounded = false
                self.view?.playerLayer.player = self.player
            })
        }
        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

        func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) { pipActive = true }
        func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { pipActive = false }
        func pictureInPictureController(_ c: AVPictureInPictureController,
                                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            Task { @MainActor in PlayerModel.shared.expanded = true }
            completionHandler(true)
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemGreen
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - The stage: video + RumbleSkip overlays + controls + gestures

struct PlayerStage: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var library: LibraryStore
    var isFullscreen: Bool

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var flash: Flash?
    @State private var scrubbing: Double?
    @State private var boostedByHold = false
    @GestureState private var holding = false

    struct Flash: Equatable { var text: String; var icon: String; var side: Int } // -1 left, 0 center, 1 right

    private var prefs: AppPreferences { library.data.prefs }

    var body: some View {
        ZStack {
            Color.black
            if player.stream != nil, player.error == nil, !player.audioOnly {
                // Audio only: no video layer at all, so nothing renders and picture-in-picture can't start.
                PlayerSurface(player: player.player, fill: player.zoomFill, enablePiP: !isFullscreen)
            }
            if player.audioOnly { audioOnlyArt.allowsHitTesting(false) }
            gestureLayer
            if let error = player.error { errorView(error) }
            else if player.loading || player.stream == nil { ProgressView().tint(.white) }
            if controlsVisible && player.error == nil && !player.loading { controls.transition(.opacity) }
            // One bar at a time: a thin progress line only while the full controls are hidden (like YouTube).
            if !controlsVisible && !isFullscreen && player.detail?.liveStatus != .isLive {
                SegmentBar(segments: player.segments, duration: player.duration, currentTime: player.currentTime,
                           settings: library.data.skip)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            flashView
            if player.boosting {
                Label("\(rateText(prefs.boostRate))×", systemImage: "forward.fill")
                    .font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 10)
            }
            skipOverlays
            if player.audioOnly && !controlsVisible {
                Button { player.setAudioOnly(false) } label: {
                    Label("Show video", systemImage: "play.rectangle").font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .background(.black.opacity(0.55), in: Capsule())
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 14)
            }
            if let n = player.autoplayCountdown, let next = player.upNext { autoplayCard(next, seconds: n) }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: player.notice)
        .animation(.easeInOut(duration: 0.2), value: player.buttonSegment)
        .onChange(of: holding) { h in
            if h { player.startBoost(); boostedByHold = true } else if boostedByHold { player.endBoost(); boostedByHold = false }
        }
        .onChange(of: player.isPlaying) { playing in if playing { scheduleHide() } else { show() } }
        .onAppear { scheduleHide() }
    }

    private var audioOnlyArt: some View {
        ZStack {
            if let t = player.detail?.thumbnail ?? player.item?.thumbnail, let u = URL(string: t) {
                AsyncImage(url: u) { $0.image?.resizable().scaledToFill() }.blur(radius: 18).opacity(0.55)
            }
            VStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 34, weight: .semibold))
                Text("Audio only").font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
        }
        .clipped()
    }

    /// End-of-video autoplay: shows what's next with a countdown, Cancel and Play now.
    private func autoplayCard(_ next: VideoItem, seconds: Int) -> some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 10) {
                Text("Up next in \(seconds)").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                HStack(spacing: 10) {
                    Thumbnail(item: next).frame(width: isFullscreen ? 200 : 120).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(next.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(next.channelName ?? "").font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                HStack(spacing: 12) {
                    Button("Cancel") { player.cancelAutoplay() }.buttonStyle(.bordered).tint(.white)
                    Button("Play now") { player.playUpNext() }.buttonStyle(.borderedProminent).tint(.accentColor)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .transition(.opacity)
    }

    // MARK: gestures

    private var gestureLayer: some View {
        GeometryReader { g in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { v in doubleTap(at: v.location.x, width: g.size.width) }
                        .exclusively(before: SpatialTapGesture(count: 1).onEnded { _ in toggleControls() })
                )
                .simultaneousGesture(longPressGesture)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24).onEnded { v in
                        guard !boostedByHold, abs(v.translation.height) > abs(v.translation.width),
                              abs(v.translation.height) > 60 else { return }
                        run(v.translation.height < 0 ? .swipeUp : .swipeDown)
                    }
                )
                .simultaneousGesture(
                    MagnificationGesture().onEnded { scale in
                        guard abs(scale - 1) > 0.12 else { return }
                        if prefs.action(for: .pinch) == .toggleZoom { player.zoomFill = scale > 1 }
                        else { run(.pinch) }
                    }
                )
        }
    }

    private var longPressGesture: AnyGesture<Void> {
        if prefs.action(for: .longPress) == .speedBoost {
            return AnyGesture(
                LongPressGesture(minimumDuration: 0.4).sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($holding) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    }
                    .map { _ in () })
        }
        return AnyGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in run(.longPress) }.map { _ in () })
    }

    private func doubleTap(at x: CGFloat, width: CGFloat) {
        let zone: PlayerGesture = x < width / 3 ? .doubleTapLeft : (x > width * 2 / 3 ? .doubleTapRight : .doubleTapCenter)
        run(zone)
    }

    private func run(_ g: PlayerGesture) {
        let action = prefs.action(for: g)
        guard action != .none else { return }
        let side = g == .doubleTapLeft ? -1 : (g == .doubleTapRight ? 1 : 0)
        switch action {
        case .seekBack: showFlash("\(prefs.seekSeconds)s", "backward.fill", side == 0 ? -1 : side)
        case .seekForward: showFlash("\(prefs.seekSeconds)s", "forward.fill", side == 0 ? 1 : side)
        case .playPause: showFlash(player.isPlaying ? "Paused" : "Play", player.isPlaying ? "pause.fill" : "play.fill", 0)
        case .skipSegment: showFlash("Skip", "forward.end.fill", side)
        default: break
        }
        player.perform(action)
    }

    // MARK: controls

    private var controls: some View {
        ZStack {
            Color.black.opacity(0.35).allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer()
                centerButtons
                Spacer()
                bottomBar
            }
            .padding(isFullscreen ? 20 : 8)
            .foregroundStyle(.white)
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button {
                if isFullscreen { player.fullscreen = false } else { player.expanded = false }
            } label: { Image(systemName: isFullscreen ? "xmark" : "chevron.down").font(.title3.weight(.semibold)) }
            if isFullscreen, let t = player.detail?.title ?? player.item?.title {
                Text(t).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            AirPlayButton().frame(width: 28, height: 28)
            if player.pip != nil && !isFullscreen {
                Button { player.pip?.startPictureInPicture() } label: { Image(systemName: "pip.enter") }
            }
            settingsMenu
        }
        .font(.title3)
    }

    private var settingsMenu: some View {
        Menu {
            Menu {
                ForEach(AppPreferences.rateChoices, id: \.self) { r in
                    Button { player.setRate(r) } label: {
                        if abs(player.rate - r) < 0.01 { Label(rateText(r) + "×", systemImage: "checkmark") } else { Text(rateText(r) + "×") }
                    }
                }
            } label: { Label("Speed · \(rateText(player.rate))×", systemImage: "speedometer") }
            if let d = player.detail, d.streams.count > 1 {
                Menu {
                    ForEach(d.streams) { s in
                        Button { player.select(s) } label: {
                            if s == player.stream { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                        }
                    }
                } label: { Label("Quality · \(player.stream?.label ?? "Auto")", systemImage: "slider.horizontal.3") }
            }
            Button { player.zoomFill.toggle() } label: {
                Label(player.zoomFill ? "Fit to screen" : "Zoom to fill", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        } label: { Image(systemName: "gearshape") }
    }

    private var centerButtons: some View {
        HStack(spacing: isFullscreen ? 70 : 44) {
            Button { player.seek(by: -Double(prefs.seekSeconds)) } label: {
                Image(systemName: "gobackward.\(prefs.seekSeconds)").font(.system(size: 26, weight: .semibold))
            }
            Button { player.togglePlay(); scheduleHide() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 42))
                    .frame(width: 64, height: 64)
            }
            Button { player.seek(by: Double(prefs.seekSeconds)) } label: {
                Image(systemName: "goforward.\(prefs.seekSeconds)").font(.system(size: 26, weight: .semibold))
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if player.isLive {
                    Button { player.goLive(); scheduleHide() } label: {
                        HStack(spacing: 5) {
                            Circle().fill(player.atLiveEdge ? Color.red : Color.white.opacity(0.6)).frame(width: 7, height: 7)
                            Text("LIVE").font(.caption2.weight(.heavy))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(player.atLiveEdge ? Color.red.opacity(0.9) : Color.white.opacity(0.22), in: Capsule())
                    }
                    .accessibilityLabel(player.atLiveEdge ? "Live" : "Jump to live")
                    if !player.atLiveEdge {
                        Text("-" + TimeFormat.clock(liveScrubBehind)).font(.caption.weight(.medium)).monospacedDigit()
                    }
                } else {
                    Text("\(TimeFormat.clock(scrubbing ?? player.currentTime)) / \(TimeFormat.clock(player.duration))")
                        .font(.caption.weight(.medium)).monospacedDigit()
                    if let c = Timestamps.current(player.chapters, at: scrubbing ?? player.currentTime) {
                        Text("· \(c.title)").font(.caption.weight(.medium)).lineLimit(1)
                    }
                }
                Spacer()
                Button { player.fullscreen.toggle() } label: {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.body.weight(.semibold))
                }
            }
            if !player.isLive || player.liveWindow != nil { scrubber }
        }
    }

    /// Seconds behind live, following the finger while scrubbing.
    private var liveScrubBehind: Double {
        guard let w = player.liveWindow else { return 0 }
        return max(0, w.upperBound - (scrubbing ?? player.currentTime))
    }

    private var scrubber: some View {
        GeometryReader { g in
            let lo = player.liveWindow?.lowerBound ?? 0
            let hi = player.liveWindow?.upperBound ?? max(player.duration, 1)
            let span = max(hi - lo, 1)
            let t = scrubbing ?? player.currentTime
            let f = min(1, max(0, (t - lo) / span))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
                Capsule().fill(Color.rumbleGreen).frame(width: g.size.width * f, height: 4)
                if !player.isLive {
                    // chapter boundaries: small gaps in the bar
                    ForEach(player.chapters.dropFirst(), id: \.self) { c in
                        Rectangle().fill(Color.black.opacity(0.85)).frame(width: 2, height: 6)
                            .offset(x: g.size.width * c.start / span - 1)
                    }
                    ForEach(player.segments.filter { library.data.skip.action(for: $0.category) != .off }) { s in
                        Rectangle().fill(s.category.color)
                            .frame(width: max(2, g.size.width * (s.end - s.start) / span), height: 4)
                            .offset(x: g.size.width * s.start / span)
                    }
                }
                Circle().fill(Color.rumbleGreen)
                    .frame(width: scrubbing == nil ? 12 : 18, height: scrubbing == nil ? 12 : 18)
                    .offset(x: g.size.width * f - (scrubbing == nil ? 6 : 9))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        scrubbing = lo + min(max(0, v.location.x / g.size.width), 1) * span
                        hideTask?.cancel()
                    }
                    .onEnded { _ in
                        if let s = scrubbing {
                            if player.isLive && hi - s < 5 { player.goLive() } else { player.seek(to: s) }
                        }
                        scrubbing = nil
                        scheduleHide()
                    }
            )
        }
        .frame(height: 22)
    }

    // MARK: overlays

    @ViewBuilder private var flashView: some View {
        if let f = flash {
            HStack {
                if f.side == 1 { Spacer() }
                VStack(spacing: 4) {
                    Image(systemName: f.icon).font(.title2)
                    Text(f.text).font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(18)
                .background(Circle().fill(Color.black.opacity(0.45)))
                .padding(.horizontal, 30)
                if f.side == -1 { Spacer() }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var skipOverlays: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                if let seg = player.notice {
                    HStack(spacing: 8) {
                        Circle().fill(seg.category.color).frame(width: 8, height: 8)
                        Text("Skipped \(seg.category.name.lowercased())").font(.caption.weight(.medium))
                        Button("Undo") { player.unskip(seg) }.font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                        Button { player.dismissNotice() } label: { Image(systemName: "xmark").font(.caption2) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
                    .transition(.opacity)
                }
                Spacer()
                if let seg = player.buttonSegment {
                    Button { player.skip(seg) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(seg.category.color).frame(width: 8, height: 8)
                            Text("Skip \(seg.category.name.lowercased())").font(.caption.weight(.bold))
                            Image(systemName: "forward.end.fill").font(.caption)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.3)))
                    }
                    .foregroundStyle(.white)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, controlsVisible ? (isFullscreen ? 80 : 56) : 12)
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(error).font(.footnote).multilineTextAlignment(.center).padding(.horizontal)
            Button("Retry") { player.retry() }.buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }

    // MARK: helpers

    private func toggleControls() { controlsVisible ? (controlsVisible = false) : show() }

    private func show() {
        controlsVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard player.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, scrubbing == nil else { return }
            controlsVisible = false
        }
    }

    private func showFlash(_ text: String, _ icon: String, _ side: Int) {
        withAnimation(.easeOut(duration: 0.15)) { flash = Flash(text: text, icon: icon, side: side) }
        let current = flash
        Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            if flash == current { withAnimation { flash = nil } }
        }
    }

    private func rateText(_ r: Double) -> String { String(format: "%g", r) }
}

// MARK: - Fullscreen

struct FullscreenPlayer: View {
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        PlayerStage(isFullscreen: true)
            .ignoresSafeArea()
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onAppear { OrientationLock.set(.landscape) }
            .onDisappear { OrientationLock.set(.portrait) }
    }
}
