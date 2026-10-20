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
        .frame(height: 4)
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
    @State private var more: [VideoItem] = []
    @State private var channelAvatar: String?
    @State private var moreFor: String?

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.vertical, 6)
            videoArea
            SegmentBar(segments: player.segments, duration: player.duration, currentTime: player.currentTime,
                       settings: library.data.skip)
            ScrollView { details.padding(.bottom, 40) }
        }
        .background(Color(.systemBackground))
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
        .task(id: player.detail?.channel?.path) { await loadMore() }
        .fullScreenCover(isPresented: $player.fullscreen) {
            FullscreenPlayer().environmentObject(player).environmentObject(library)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard library.data.prefs.rotateToFullscreen, player.stream != nil else { return }
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
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
                    }
                    Text(meta(d, item)).font(.caption).foregroundStyle(.secondary)
                }
            }
            actions(item, d)
            if let c = d?.channel ?? item?.channel { channelRow(c, followers: d?.channelFollowers) }
            if let desc = d?.description, !desc.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(desc).font(.footnote).lineLimit(expandedDescription ? nil : 3)
                    Button(expandedDescription ? "Show less" : "Show more") { expandedDescription.toggle() }
                        .font(.footnote.weight(.semibold))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
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
        if let v = d?.views { parts.append("\(CountFormat.short(v)) views") } else if let v = item?.views { parts.append("\(v) views") }
        if let p = d?.published ?? item?.publishedDate { parts.append(DateParsing.relative(p)) }
        return parts.joined(separator: " · ")
    }

    private func actions(_ item: VideoItem?, _ d: VideoDetail?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let likes = d?.likes {
                    pill(Label(likes, systemImage: "hand.thumbsup"))
                }
                Button { showComments = true } label: {
                    pill(Label("Comments", systemImage: "text.bubble"))
                }
                Button { showSkipPanel = true } label: {
                    pill(Label(player.segments.isEmpty ? "RumbleSkip" : "RumbleSkip · \(player.segments.count)",
                               systemImage: "forward.end.alt"), highlight: !player.segments.isEmpty)
                }
                if let item {
                    Button { library.data.toggleWatchLater(item) } label: {
                        pill(Label("Save", systemImage: library.data.inWatchLater(item.id) ? "clock.fill" : "clock"))
                    }
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
                    ChannelAvatar(name: c.name, url: c.avatar ?? channelAvatar ?? player.item?.channelAvatar, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let f = followers { Text("\(f) followers").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            let following = library.data.isFollowing(c.path)
            Button(following ? "Following" : "Follow") { library.data.toggleFollow(c) }
                .buttonStyle(.borderedProminent)
                .tint(following ? Color.secondary.opacity(0.3) : Color.rumbleGreen)
                .foregroundStyle(following ? Color.primary : Color.black)
                .font(.subheadline.weight(.semibold))
        }
    }

    private func loadMore() async {
        guard let path = player.detail?.channel?.path, moreFor != path else { return }
        moreFor = path
        more = []
        channelAvatar = nil
        if let page = try? await RumbleService.shared.channel(path) {
            more = page.items
            channelAvatar = page.channel?.avatar ?? page.items.first(where: { $0.channelAvatar != nil })?.channelAvatar
        }
    }
}

// MARK: - Mini player

struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        if let item = player.item, !player.expanded {
            VStack(spacing: 0) {
                GeometryReader { g in
                    Rectangle().fill(Color.rumbleGreen)
                        .frame(width: player.duration > 0 ? g.size.width * min(1, player.currentTime / player.duration) : 0)
                }
                .frame(height: 2)
                HStack(spacing: 10) {
                    Thumbnail(item: item).frame(width: 96).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.detail?.title ?? item.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        Text(player.detail?.channel?.name ?? item.channelName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 40, height: 40)
                    }
                    Button { player.close() } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 40)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .background(.regularMaterial)
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .onTapGesture { player.expanded = true }
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                if v.translation.height < -30 { player.expanded = true }
            })
        }
    }
}
