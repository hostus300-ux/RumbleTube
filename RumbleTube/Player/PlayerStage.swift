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
            if player.stream != nil, player.error == nil {
                PlayerSurface(player: player.player, fill: player.zoomFill, enablePiP: !isFullscreen)
            }
            gestureLayer
            if let error = player.error { errorView(error) }
            else if player.loading || player.stream == nil { ProgressView().tint(.white) }
            if controlsVisible && player.error == nil && !player.loading { controls.transition(.opacity) }
            flashView
            if player.boosting {
                Label("\(rateText(prefs.boostRate))×", systemImage: "forward.fill")
                    .font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 10)
            }
            skipOverlays
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
            HStack {
                if player.detail?.liveStatus == .isLive {
                    Text("LIVE").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 3))
                } else {
                    Text("\(TimeFormat.clock(scrubbing ?? player.currentTime)) / \(TimeFormat.clock(player.duration))")
                        .font(.caption.weight(.medium)).monospacedDigit()
                }
                Spacer()
                Button { player.fullscreen.toggle() } label: {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.body.weight(.semibold))
                }
            }
            if player.detail?.liveStatus != .isLive { scrubber }
        }
    }

    private var scrubber: some View {
        GeometryReader { g in
            let d = max(player.duration, 1)
            let t = scrubbing ?? player.currentTime
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: g.size.width * min(1, t / d), height: 4)
                ForEach(player.segments.filter { library.data.skip.action(for: $0.category) != .off }) { s in
                    Rectangle().fill(s.category.color)
                        .frame(width: max(2, g.size.width * (s.end - s.start) / d), height: 4)
                        .offset(x: g.size.width * s.start / d)
                }
                Circle().fill(Color.accentColor).frame(width: scrubbing == nil ? 12 : 18, height: scrubbing == nil ? 12 : 18)
                    .offset(x: g.size.width * min(1, t / d) - (scrubbing == nil ? 6 : 9))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        scrubbing = min(max(0, v.location.x / g.size.width), 1) * d
                        hideTask?.cancel()
                    }
                    .onEnded { _ in
                        if let s = scrubbing { player.seek(to: s) }
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
