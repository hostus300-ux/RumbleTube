import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snapshot: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? .sample : WidgetShared.load() ?? .sample))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app refreshes the data and reloads widgets; this is just a fallback refresh.
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetShared.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

extension WidgetSnapshot {
    static var sample: WidgetSnapshot {
        var s = WidgetSnapshot()
        s.signedIn = true
        s.liveNow = [.init(name: "Live channel", path: "/c/x", viewers: 12_400), .init(name: "Another show", path: "/c/y", viewers: 830)]
        s.continueWatching = [.init(id: "v1", title: "A video you started", channel: "Channel", url: "https://rumble.com/", progress: 0.4)]
        return s
    }
}

private let green = Color(red: 0x85 / 255, green: 0xC7 / 255, blue: 0x42 / 255)

private func short(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
    default: return "\(n)"
    }
}

private struct Avatar: View {
    let data: Data?
    let name: String
    var size: CGFloat = 28
    var body: some View {
        Group {
            if let data, let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
            else { Text(String(name.prefix(1)).uppercased()).font(.caption.bold()).foregroundStyle(green) }
        }
        .frame(width: size, height: size)
        .background(green.opacity(0.2))
        .clipShape(Circle())
    }
}

// MARK: - Live now

struct LiveNowView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let live = entry.snapshot?.liveNow ?? []
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text("Live now").font(.caption.weight(.bold))
                Spacer()
            }
            if entry.snapshot == nil {
                Text("Open Rumble once to set this up.").font(.caption2).foregroundStyle(.secondary)
            } else if live.isEmpty {
                Text("None of the channels you follow are live.").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(live.prefix(family == .systemSmall ? 3 : 4), id: \.self) { c in
                    Link(destination: WidgetShared.deepLink("https://rumble.com\(c.path)") ?? URL(string: "rumbletube://")!) {
                        HStack(spacing: 6) {
                            Avatar(data: c.avatar, name: c.name, size: family == .systemSmall ? 20 : 24)
                            Text(c.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 2)
                            if let v = c.viewers { Text(short(v)).font(.caption2.monospacedDigit()).foregroundStyle(.red) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .widgetBackground()
    }
}

struct LiveNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LiveNow", provider: SnapshotProvider()) { LiveNowView(entry: $0) }
            .configurationDisplayName("Live now")
            .description("Channels you follow that are live right now.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Continue watching

struct ContinueWatchingView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let vids = entry.snapshot?.continueWatching ?? []
        VStack(alignment: .leading, spacing: 6) {
            Text("Continue watching").font(.caption.weight(.bold))
            if vids.isEmpty {
                Text("Videos you start show up here.").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if family == .systemSmall, let v = vids.first {
                card(v)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(vids.prefix(2), id: \.self) { card($0) }
                }
            }
        }
        .widgetBackground()
    }

    private func card(_ v: WidgetSnapshot.Video) -> some View {
        Link(destination: WidgetShared.deepLink(v.url) ?? URL(string: "rumbletube://")!) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let d = v.thumb, let img = UIImage(data: d) { Image(uiImage: img).resizable().scaledToFill() }
                        else { Color.gray.opacity(0.3) }
                    }
                    .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit).clipped()
                    GeometryReader { g in
                        Rectangle().fill(green).frame(width: g.size.width * v.progress, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(v.title).font(.caption2.weight(.semibold)).lineLimit(2)
            }
        }
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatching", provider: SnapshotProvider()) { ContinueWatchingView(entry: $0) }
            .configurationDisplayName("Continue watching")
            .description("Pick up where you left off.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Live Activity (Lock Screen + Dynamic Island)

private let accent = green

@available(iOS 16.1, *)
private struct ActivityProgress: View {
    let state: LiveStreamAttributes.ContentState
    var body: some View {
        if state.isLive {
            HStack(spacing: 5) {
                Circle().fill(state.behindLive < 20 ? Color.red : Color.gray).frame(width: 7, height: 7)
                Text(state.behindLive < 20 ? "LIVE" : "-\(clock(state.behindLive))").font(.caption2.weight(.heavy)).monospacedDigit()
                if let v = state.viewers { Text("· \(short(v)) watching").font(.caption2).foregroundStyle(.secondary) }
            }
        } else if state.duration > 0 {
            // Animates on its own between updates while playing.
            let start = state.updatedAt.addingTimeInterval(-state.position)
            let end = start.addingTimeInterval(state.duration)
            if state.isPlaying, end > Date() {
                ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(accent)
            } else {
                ProgressView(value: min(1, state.position / state.duration)).tint(accent)
            }
        }
    }
}

@available(iOS 16.1, *)
private struct ActivityButtons: View {
    let state: LiveStreamAttributes.ContentState
    var size: CGFloat = 20
    var body: some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 22) {
                Button(intent: SkipIntent(seconds: -10)) { Image(systemName: "gobackward.10").font(.system(size: size, weight: .semibold)) }
                Button(intent: TogglePlayIntent()) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.system(size: size + 4, weight: .bold))
                }
                if state.isLive && state.behindLive >= 20 {
                    Button(intent: GoLiveIntent()) { Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: size, weight: .semibold)) }
                } else {
                    Button(intent: SkipIntent(seconds: 10)) { Image(systemName: "goforward.10").font(.system(size: size, weight: .semibold)) }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        } else {
            Image(systemName: state.isPlaying ? "play.fill" : "pause.fill").font(.title3)
        }
    }
}

private func clock(_ s: Int) -> String {
    s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

@available(iOS 16.1, *)
struct LiveStreamActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveStreamAttributes.self) { ctx in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ctx.attributes.audioOnly ? "waveform" : "dot.radiowaves.left.and.right")
                        .font(.title3.weight(.semibold)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ctx.attributes.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(ctx.attributes.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                ActivityProgress(state: ctx.state)
                ActivityButtons(state: ctx.state).frame(maxWidth: .infinity)
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.65))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: ctx.attributes.audioOnly ? "waveform" : "dot.radiowaves.left.and.right")
                        .foregroundStyle(ctx.state.isLive ? .red : accent).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let v = ctx.state.viewers, ctx.state.isLive { Label(short(v), systemImage: "eye").font(.caption) }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(ctx.attributes.title).font(.caption.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        ActivityProgress(state: ctx.state)
                        ActivityButtons(state: ctx.state, size: 22)
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                Image(systemName: ctx.attributes.audioOnly ? "waveform" : "circle.fill")
                    .foregroundStyle(ctx.state.isLive ? .red : accent).font(.caption2)
            } compactTrailing: {
                if ctx.state.isLive {
                    Text(ctx.state.viewers.map(short) ?? "LIVE").font(.caption2.monospacedDigit())
                } else {
                    Image(systemName: ctx.state.isPlaying ? "pause.fill" : "play.fill").font(.caption2)
                }
            } minimal: {
                Image(systemName: ctx.attributes.audioOnly ? "waveform" : "circle.fill").foregroundStyle(accent).font(.caption2)
            }
        }
    }
}

// MARK: - Bundle

@main
struct RumbleWidgetBundle: WidgetBundle {
    var body: some Widget {
        LiveNowWidget()
        ContinueWatchingWidget()
        LiveStreamActivity()
    }
}

extension View {
    /// iOS 17 requires a container background; iOS 16 uses padding.
    @ViewBuilder func widgetBackground() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(for: .widget) { Color(.systemBackground) }
        } else {
            self.padding()
        }
    }
}
