import AVKit
import SwiftUI

// MARK: - Segment bar under the video

struct SegmentBar: View {
    let segments: [SkipSegment]
    let duration: Double
    let currentTime: Double
    let settings: SkipSettings

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12))
                if duration > 0 {
                    Rectangle().fill(Color.white.opacity(0.35))
                        .frame(width: g.size.width * min(1, max(0, currentTime / duration)))
                    ForEach(segments.filter { settings.action(for: $0.category) != .off }) { s in
                        Rectangle().fill(s.category.color)
                            .frame(width: max(2, g.size.width * (s.end - s.start) / duration))
                            .offset(x: g.size.width * s.start / duration)
                    }
                }
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Full player screen

struct PlayerScreen: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var router: Router
    @EnvironmentObject var account: AccountStore
    @State private var showSkipPanel = false
    @State private var showComments = false
    @State private var expandedDescription = false
    private var more: [VideoItem] { player.more }
    @State private var channelAvatar: String?
    @State private var moreFor: String?
    @StateObject private var chat = LiveChatModel()
    @State private var showChat = true
    /// Videos: the Comments button swaps the details area for comments until you close them.
    @State private var commentsOpen = false
    /// Live streams: details live in a sheet so the chat gets the whole space.
    @State private var showLiveDetails = false

    /// Comments as a section of the player (readable, no floating card).
    @ViewBuilder private var inlineComments: some View {
        if let item = player.item {
            CommentsScreen(target: CommentTarget(
                video: item,
                listID: player.detail.map { $0.embedId.hasPrefix("v") ? String($0.embedId.dropFirst()) : $0.embedId },
                videoNumericID: nil, focusCommentID: nil), inline: true)
            .id(item.id)
        }
    }

    private var liveChat: ChatConfig? {
        guard let d = player.detail, d.liveStatus == .isLive else { return nil }
        return d.chat
    }

    @Environment(\.horizontalSizeClass) private var hsc

    var body: some View {
        applySheets(
            Group {
                // iPad only: an iPhone rotating to fullscreen briefly reports a regular width, which flashed this layout.
                if hsc == .regular && UIDevice.current.userInterfaceIdiom == .pad { wideLayout } else { phoneLayout }
            }
            .task(id: liveChat) {
                if let c = liveChat { chat.start(c) } else { chat.stop() }
            }
            .onDisappear { chat.stop() }
            .onChange(of: player.item?.id) { _ in commentsOpen = false }
            .background(Color(.systemBackground))
        )
    }

    /// iPad / wide windows: video and details on the left, live chat (or More from) on the right.
    private var wideLayout: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.vertical, 6)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    videoArea
                    if commentsOpen {
                        commentsHeader
                        inlineComments
                    } else {
                        ScrollView { details.padding(.bottom, 40) }
                    }
                }
                .frame(maxWidth: .infinity)
                Divider()
                Group {
                    if liveChat != nil {
                        VStack(spacing: 0) {
                            Text("Live chat").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            LiveChatView(chat: chat, videoURL: player.detail.flatMap { URL(string: $0.url) },
                                         channel: player.detail?.channel ?? player.item?.channel)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                Text("More from \(player.detail?.channel?.name ?? "this channel")").font(.headline)
                                ForEach(more.filter { $0.id != player.item?.id }.prefix(20)) { v in
                                    Button { player.play(v) } label: { VideoRow(item: v) }.buttonStyle(.plain)
                                }
                            }
                            .padding(12)
                        }
                    }
                }
                .frame(width: 380)
            }
        }
    }

    private var phoneLayout: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.vertical, 6)
            videoArea
            if liveChat != nil {
                // Live: a slim title strip, then the chat. Tap the strip for the full details.
                liveStrip
                Divider()
                LiveChatView(chat: chat, videoURL: player.detail.flatMap { URL(string: $0.url) },
                             channel: player.detail?.channel ?? player.item?.channel)
            } else if commentsOpen {
                commentsHeader
                inlineComments
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ScrollView { details.padding(.bottom, 40) }
            }
        }
    }

    private var commentsHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Comments").font(.headline)
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.2)) { commentsOpen = false } } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold))
                        .frame(width: 32, height: 32).background(Color.secondary.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close comments")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
        }
    }

    /// Live streams: title, LIVE + viewers, and the channel, in one compact row above the chat.
    private var liveStrip: some View {
        let d = player.detail, item = player.item
        return Button { showLiveDetails = true } label: {
            HStack(spacing: 10) {
                ChannelAvatar(name: d?.channel?.name ?? item?.channelName ?? "?",
                              url: d?.channel?.avatar ?? channelAvatar ?? item?.channelAvatar, size: 34,
                              path: d?.channel?.path ?? item?.channelPath)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d?.title ?? item?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("LIVE").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.rumbleRed, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
                        Text([d?.channel?.name ?? item?.channelName, meta(d, item)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                // Opens the details panel (a sheet that comes up), so an info icon, not an arrow.
                Image(systemName: "info.circle").font(.title3).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the stream's details")
    }

    private func applySheets<V: View>(_ v: V) -> some View {
        v
        .onChange(of: player.openSkipPanel) { open in
            if open { showSkipPanel = true; player.openSkipPanel = false }
        }
        .sheet(isPresented: $showSkipPanel) {
            SkipPanel().environmentObject(player).environmentObject(library)
        }
        .sheet(isPresented: $showComments) {
            if let item = player.item {
                NavigationStack {
                    CommentsScreen(target: CommentTarget(
                        video: item,
                        listID: player.detail.map { $0.embedId.hasPrefix("v") ? String($0.embedId.dropFirst()) : $0.embedId },
                        videoNumericID: nil, focusCommentID: nil))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showComments = false } } }
                }
                .environmentObject(account).environmentObject(player).environmentObject(library).environmentObject(router)
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showLiveDetails) {
            NavigationStack {
                ScrollView { details.padding(.bottom, 30) }
                    .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showLiveDetails = false } } }
            }
            .environmentObject(account).environmentObject(player).environmentObject(library).environmentObject(router)
            .presentationDetents([.medium, .large])
        }
        .task(id: player.detail?.channel?.path) { await loadMore() }
        .fullScreenCover(isPresented: $player.fullscreen) {
            FullscreenPlayer().environmentObject(player).environmentObject(library)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard library.data.prefs.rotateToFullscreen, player.stream != nil,
                  UIDevice.current.userInterfaceIdiom != .pad else { return }
            let o = UIDevice.current.orientation
            if o.isLandscape, !player.fullscreen { player.fullscreen = true }
            else if o == .portrait, player.fullscreen { player.fullscreen = false }
        }
    }

    private var videoArea: some View {
        PlayerStage(isFullscreen: false)
            .aspectRatio(16 / 9, contentMode: .fit)
    }

    // MARK: details

    @ViewBuilder private var details: some View {
        let item = player.item
        let d = player.detail
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(d?.title ?? item?.title ?? "").font(.headline)
                HStack(spacing: 6) {
                    if d?.liveStatus == .isLive {
                        Text("LIVE").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.rumbleRed, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
                    }
                    Text(meta(d, item)).font(.caption).foregroundStyle(.secondary)
                }
            }
            actions(item, d)
            if let c = d?.channel ?? item?.channel {
                channelRow(c, followers: d?.channelFollowers)
                CreatorButtons(channel: c, joinable: d?.channelJoinable == true, tipID: d?.tipID)
            }
            if let desc = d?.description, !desc.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !player.chapters.isEmpty && expandedDescription == false {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(player.chapters, id: \.self) { c in
                                    Button { player.seek(to: c.start) } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(TimeFormat.clock(c.start)).font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                                            Text(c.title).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                                        }
                                        .frame(width: 130, alignment: .leading)
                                        .padding(8)
                                        .background(player.currentChapter == c ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                                                    in: RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Text(SeekLinks.attributed(desc)).font(.footnote).lineLimit(expandedDescription ? nil : 3)
                        .seekLinks(for: nil, player: player)
                    Button(expandedDescription ? "Show less" : "Show more") {
                        withAnimation(.easeInOut(duration: 0.2)) { expandedDescription.toggle() }
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
                // Tap anywhere on the collapsed description to open it; "Show less" closes it.
                .onTapGesture {
                    guard !expandedDescription else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { expandedDescription = true }
                }
            }
            upNextRow
            if !more.isEmpty {
                Text("More from \(d?.channel?.name ?? "this channel")").font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(more.filter { $0.id != item?.id }.prefix(12)) { v in
                    Button { player.play(v) } label: { VideoRow(item: v) }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func meta(_ d: VideoDetail?, _ item: VideoItem?) -> String {
        var parts: [String] = []
        if d?.liveStatus == .isLive {
            if let n = player.liveViewers ?? item?.watching { parts.append("\(n.formatted()) watching now") }
        } else if let v = d?.views { parts.append("\(CountFormat.short(v)) views") } else if let v = item?.views { parts.append("\(v) views") }
        if let p = d?.published ?? item?.publishedDate { parts.append(DateParsing.relative(p)) }
        return parts.joined(separator: " · ")
    }

    private func actions(_ item: VideoItem?, _ d: VideoDetail?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if d?.likes != nil || d?.dislikes != nil {
                    // Rumble shows dislikes publicly, so they're shown here too.
                    HStack(spacing: 12) {
                        Label(d?.likes ?? "0", systemImage: "hand.thumbsup")
                        Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1, height: 16)
                        Label(d?.dislikes ?? "0", systemImage: "hand.thumbsdown")
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                if d?.liveStatus != .isLive {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { commentsOpen = true } } label: {
                        pill(Label("Comments", systemImage: "text.bubble"))
                    }
                }
                Button { showSkipPanel = true } label: {
                    pill(Label(player.segments.isEmpty ? "RumbleSkip" : "RumbleSkip · \(player.segments.count)",
                               systemImage: "forward.end.alt"), highlight: !player.segments.isEmpty)
                }
                if let item, d?.liveStatus != .isLive {
                    DownloadPill(item: item)
                }
                if let item {
                    Button { library.data.toggleWatchLater(item) } label: {
                        pill(Label("Save", systemImage: library.data.inWatchLater(item.id) ? "clock.fill" : "clock"))
                    }
                }
                Button { player.setAudioOnly(!player.audioOnly) } label: {
                    pill(Label("Audio only", systemImage: player.audioOnly ? "waveform.circle.fill" : "waveform"),
                         highlight: player.audioOnly)
                }
                if let d, d.streams.count > 1 {
                    Menu {
                        ForEach(d.streams) { s in
                            Button { player.select(s) } label: {
                                if s == player.stream { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                            }
                        }
                    } label: {
                        pill(Label(player.stream?.label ?? "Quality", systemImage: "slider.horizontal.3"))
                    }
                }
                if let s = item?.url, let url = URL(string: s) {
                    ShareLink(item: url) { pill(Label("Share", systemImage: "square.and.arrow.up")) }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func pill(_ label: Label<Text, Image>, highlight: Bool = false) -> some View {
        label.font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(highlight ? Color.rumbleGreen.opacity(0.25) : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(highlight ? Color.rumbleGreen : Color.primary)
    }

    private func channelRow(_ c: ChannelRef, followers: String?) -> some View {
        HStack(spacing: 10) {
            Button { router.open(c) } label: {
                HStack(spacing: 10) {
                    ChannelAvatar(name: c.name, url: c.avatar ?? channelAvatar ?? player.item?.channelAvatar, size: 40, path: c.path)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(c.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if player.detail?.channelVerified == true { VerifiedBadge(size: 12) }
                        }
                        if let f = followers { Text("\(f) followers").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { TagUI.shared.tag(c) } label: { Label("Tag channel…", systemImage: "tag") }
                if let e = library.data.muteEntry(path: c.path, name: c.name) {
                    Button(role: .destructive) { library.data.unmute(e.key) } label: { Label("Unmute channel", systemImage: "speaker.wave.2") }
                } else {
                    Button { MuteUI.shared.muteChannel(c) } label: { Label("Mute channel…", systemImage: "speaker.slash") }
                }
            }
            Spacer()
            FollowControl(channel: c)
                .id(c.id)
        }
    }

    /// "Up next" with the autoplay switch, so it's always clear what plays when this video ends.
    @ViewBuilder private var upNextRow: some View {
        if d_isVOD {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Up next").font(.subheadline.weight(.semibold))
                    Spacer()
                    Toggle("Autoplay", isOn: Binding(get: { player.autoplayOn }, set: { player.setAutoplay($0) }))
                        .font(.footnote.weight(.semibold)).fixedSize()
                }
                if let next = player.upNext {
                    Button { player.play(next) } label: { VideoRow(item: next) }.buttonStyle(.plain)
                } else {
                    Text("Nothing queued yet.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var d_isVOD: Bool { player.detail.map { $0.liveStatus != .isLive } ?? false }

    private func loadMore() async {
        guard let path = player.detail?.channel?.path, moreFor != path else { return }
        moreFor = path
        channelAvatar = nil
        if let page = try? await RumbleService.shared.channel(path) {
            channelAvatar = page.channel?.avatar ?? page.items.first(where: { $0.channelAvatar != nil })?.channelAvatar
        }
    }
}

// MARK: - Mini player

struct MiniPlayer: View {
    @ObservedObject private var clock = PlayerClock.shared   // redraw as time moves
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var library: LibraryStore
    @State private var dragX: CGFloat = 0

    var body: some View {
        if let item = player.item, !player.expanded {
            Group {
                if GlassUI.available && library.data.prefs.liquidGlass {
                    bar(item)
                        // Kept inside the card's rounded bottom edge.
                        .overlay(alignment: .bottom) { progress.clipShape(Capsule()).padding(.horizontal, 22).padding(.bottom, 4) }
                        .glassCard(22, interactive: true)
                        .padding(.horizontal, 10).padding(.bottom, 6)
                } else {
                    VStack(spacing: 0) {
                        progress
                        bar(item)
                    }
                    .background(.regularMaterial)
                }
            }
            .miniPlayerSwipe(dragX: $dragX, player: player)
        }
    }

    private var progress: some View {
        GeometryReader { g in
            Rectangle().fill(Color.rumbleGreen)
                .frame(width: player.duration > 0 ? g.size.width * min(1, player.currentTime / player.duration) : 0)
        }
        .frame(height: 2)
    }

    private func bar(_ item: VideoItem) -> some View {
                HStack(spacing: 10) {
                    MiniPlayerArt(item: item).frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.detail?.title ?? item.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        Text(player.detail?.channel?.name ?? item.channelName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        MiniPlayerTime().font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button { if player.miniPlayerArmed { player.togglePlay() } } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 40, height: 40)
                    }
                    Button { if player.miniPlayerArmed { player.close() } } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 40)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .onTapGesture { if player.miniPlayerArmed { player.expanded = true } }
    }
}

/// The mini player's picture: the plain thumbnail (no time badge: it doesn't fit). A long-press starts
/// picture-in-picture through the hidden `PiPHost` layer.
struct MiniPlayerArt: View {
    let item: VideoItem
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        ZStack {
            Color.black
            if let t = player.detail?.thumbnail ?? item.thumbnail, let u = URL(string: t) {
                AsyncImage(url: u) { $0.image?.resizable().scaledToFill() }
            }
        }
        .clipped()
        .contentShape(Rectangle())
        // Hold the mini player's picture to pop the video out into picture-in-picture.
        .onLongPressGesture(minimumDuration: 0.45) {
            guard let pip = player.pip, pip.isPictureInPicturePossible else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            pip.startPictureInPicture()
        }
        .accessibilityHint("Touch and hold for picture in picture")
    }
}

/// "1:23 / 10:05" (or LIVE) as a line of the mini player's details.
struct MiniPlayerTime: View {
    @EnvironmentObject var player: PlayerModel
    @ObservedObject private var clock = PlayerClock.shared

    var body: some View {
        if player.isLive {
            Text("LIVE").foregroundStyle(Color.rumbleRed).fontWeight(.bold)
        } else if player.duration > 0 {
            Text("\(TimeFormat.clock(clock.time)) / \(TimeFormat.clock(player.duration))")
        }
    }
}

extension View {
    /// Drag the mini player: right slides it off screen and closes the video; up opens the full player.
    func miniPlayerSwipe(dragX: Binding<CGFloat>, player: PlayerModel) -> some View {
        self
            .offset(x: dragX.wrappedValue)
            .opacity(1 - Double(min(1, dragX.wrappedValue / 500)) * 0.6)
            .simultaneousGesture(DragGesture(minimumDistance: 12)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    dragX.wrappedValue = max(0, v.translation.width)
                }
                .onEnded { v in
                    let horizontal = abs(v.translation.width) > abs(v.translation.height)
                    if !horizontal && v.translation.height < -30 {
                        dragX.wrappedValue = 0
                        player.expanded = true
                    } else if horizontal && (v.translation.width > 110 || v.predictedEndTranslation.width > 260) {
                        withAnimation(.easeIn(duration: 0.18)) { dragX.wrappedValue = UIScreen.main.bounds.width + 40 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            player.close()
                            dragX.wrappedValue = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX.wrappedValue = 0 }
                    }
                })
    }
}


// MARK: - Mini player docked in the tab bar (iOS 26.1+, Apple Music style)

#if compiler(>=6.2)
@available(iOS 26.0, *)
struct MiniPlayerAccessory: View {
    @ObservedObject private var clock = PlayerClock.shared   // redraw as time moves
    @EnvironmentObject var player: PlayerModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var dragX: CGFloat = 0

    var body: some View {
        if let item = player.item {
            let inline = placement == .inline
            HStack(spacing: 10) {
                MiniPlayerArt(item: item)
                    .frame(width: inline ? 40 : 56, height: inline ? 24 : 32)
                    .clipShape(RoundedRectangle(cornerRadius: inline ? 6 : 8))
                VStack(alignment: .leading, spacing: 0) {
                    Text(player.detail?.title ?? item.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(player.detail?.channel?.name ?? item.channelName ?? "").lineLimit(1)
                        if !inline { Text("·"); MiniPlayerTime().monospacedDigit() }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { if player.miniPlayerArmed { player.togglePlay() } } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !inline {
                    Button { if player.miniPlayerArmed { player.close() } } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold))
                            .frame(width: 32, height: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 6).padding(.trailing, 10)
            .overlay(alignment: .bottom) {
                GeometryReader { g in
                    Capsule().fill(Color.rumbleGreen)
                        .frame(width: player.duration > 0 ? g.size.width * min(1, player.currentTime / player.duration) : 0, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
                .opacity(player.isLive ? 0 : 1)
            }
            .contentShape(Rectangle())
            .onTapGesture { if player.miniPlayerArmed { player.expanded = true } }
            // The tab-bar accessory is drawn by iOS, so it can't be dragged around; a swipe still works.
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                if v.translation.height < -30 && abs(v.translation.width) < 60 { player.expanded = true }
                else if v.translation.width > 80 && abs(v.translation.height) < 60 { withAnimation(.easeOut(duration: 0.2)) { player.close() } }
            })
        }
    }
}
#else
struct MiniPlayerAccessory: View { var body: some View { EmptyView() } }
#endif


/// A tiny, nearly invisible video layer that stays on screen while the mini player is showing, so
/// picture-in-picture can start from it (iOS needs a live player layer for PiP).
struct PiPHost: View {
    @EnvironmentObject var player: PlayerModel
    var body: some View {
        if player.item != nil && !player.expanded && player.stream != nil && !player.audioOnly && player.error == nil {
            PlayerSurface(player: player.player, fill: true, enablePiP: true)
                .frame(width: 4, height: 4)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
