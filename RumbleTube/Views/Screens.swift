import SwiftUI
import UIKit

// MARK: - Channel

struct ChannelView: View {
    let channel: ChannelRef
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var account: AccountStore
    @StateObject private var model: ListingModel

    init(channel: ChannelRef) {
        self.channel = channel
        let path = channel.path
        _model = StateObject(wrappedValue: ListingModel { page in try await RumbleService.shared.channel(path, page: page) })
    }

    var body: some View {
        ListingView(model: model, style: .rows) { header.padding(.bottom, 8) }
            .navigationTitle(model.header?.name ?? channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isMine {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            if let e = library.data.muteEntry(path: channel.path, name: channel.name) {
                                Button { MuteUI.shared.muteChannel(channel) } label: { Label("Edit mute tag", systemImage: "tag") }
                                Button(role: .destructive) { library.data.unmute(e.key) } label: { Label("Unmute channel", systemImage: "speaker.wave.2") }
                            } else {
                                Button { MuteUI.shared.muteChannel(channel) } label: { Label("Mute channel…", systemImage: "speaker.slash") }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
    }

    /// Your own channel: no Follow button.
    private var isMine: Bool {
        guard let u = account.username?.lowercased() else { return false }
        return channel.path.lowercased() == "/user/\(u)" || channel.path.lowercased() == "/c/\(u)"
    }

    private var header: some View {
        let h = model.header
        let ref = ChannelRef(path: channel.path, name: h?.name ?? channel.name, avatar: h?.avatar ?? channel.avatar)
        return VStack(spacing: 10) {
            if let b = h?.banner, let url = URL(string: b) {
                AsyncImage(url: url) { $0.image?.resizable().scaledToFill() }
                    .frame(height: 90).frame(maxWidth: .infinity).clipped()
            }
            HStack(spacing: 12) {
                ChannelAvatar(name: ref.name, url: ref.avatar, size: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ref.name).font(.title3.weight(.bold)).lineLimit(2)
                    if let f = h?.followers { Text("\(f) followers").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            if !isMine {
                FollowControl(channel: ref, header: h, fullWidth: true)
            }
        }
        .onChange(of: h?.avatar) { avatar in
            // keep the stored follow's avatar/name fresh
            if let i = library.data.follows.firstIndex(where: { $0.id == channel.id }), let avatar {
                library.data.follows[i].avatar = avatar
                if let n = h?.name { library.data.follows[i].name = n }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var confirmClear = false

    private let qualities: [(String, Int?)] = [("Auto (adaptive)", nil), ("1080p", 1080), ("720p", 720), ("480p", 480), ("360p", 360)]

    private func pref<T>(_ key: WritableKeyPath<AppPreferences, T>) -> Binding<T> {
        Binding(get: { library.data.prefs[keyPath: key] }, set: { library.data.prefs[keyPath: key] = $0 })
    }

    private func tweak(_ title: String, _ icon: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(color, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    var body: some View {
        Form {
            Section {
                NavigationLink { SkipSettingsView().miniPlayerSpace() } label: { tweak("RumbleSkip", "forward.end.alt", .green) }
                NavigationLink { GestureSettingsView().miniPlayerSpace() } label: { tweak("Gestures", "hand.tap", .orange) }
                NavigationLink { TabSettingsView().miniPlayerSpace() } label: { tweak("Tabs & layout", "square.grid.2x2", .blue) }
                NavigationLink { MutedListView().miniPlayerSpace() } label: {
                    HStack {
                        tweak("Muted channels & users", "speaker.slash", .gray)
                        Spacer()
                        if !library.data.muted.isEmpty { Text("\(library.data.muted.count)").foregroundStyle(.secondary) }
                    }
                }
                Toggle(isOn: Binding(get: { library.data.skip.autoMatchYouTube },
                                     set: { library.data.skip.autoMatchYouTube = $0; PlayerModel.shared.settingsChanged() })) {
                    tweak("Auto-find YouTube skips", "wand.and.stars", .red)
                }
                Toggle(isOn: pref(\.shortsMutedWhenOtherAudio)) { tweak("Shorts start muted over my music", "speaker.wave.2", .purple) }
            } header: { Text("Tweaks") }

            AccountSettingsSection()

            Section {
                Picker("Home opens on", selection: pref(\.homeFilter)) {
                    ForEach(ContentFilter.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("Discover opens on", selection: pref(\.discoverPage)) {
                    ForEach(DiscoverModel.Page.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("Discover sorted by", selection: pref(\.discoverSort)) {
                    ForEach(DiscoverModel.Sort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("My Feed opens on", selection: pref(\.myFeedPill)) {
                    ForEach(MyFeedPill.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: { Text("Start pages") } footer: {
                Text("Which filter each tab shows when it opens.")
            }

            Section {
                Toggle("Show + (upload / go live) button", isOn: pref(\.showCreateButton))
                Toggle("Shrink tab bar while scrolling", isOn: pref(\.minimizeTabBar))
                Toggle("Liquid Glass", isOn: pref(\.liquidGlass))
                    .disabled(!GlassUI.available)
            } header: { Text("Look") } footer: {
                Text(GlassUI.available
                     ? "Glass header buttons, filter chips and a floating mini player, like Apple's own apps. The tab bar and menus always use the system look."
                     : "Liquid Glass needs iOS 26 or later.")
            }

            Section("Appearance") {
                Picker("Theme", selection: pref(\.theme)) {
                    ForEach(ThemeMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Accent colour")
                    HStack(spacing: 12) {
                        ForEach(AccentChoice.allCases) { a in
                            Circle().fill(Color(hex: a.hex)).frame(width: 30, height: 30)
                                .overlay(Circle().stroke(Color.primary, lineWidth: library.data.prefs.accent == a ? 3 : 0).padding(-4))
                                .onTapGesture { library.data.prefs.accent = a }
                                .accessibilityLabel(a.title)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }


            Section {
                Picker("Default speed", selection: pref(\.defaultRate)) {
                    ForEach(AppPreferences.rateChoices, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                Picker("Rewind / fast-forward", selection: pref(\.seekSeconds)) {
                    ForEach(AppPreferences.seekChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Default quality", selection: Binding(get: { library.data.preferredHeight ?? 0 },
                                                             set: { library.data.preferredHeight = $0 == 0 ? nil : $0 })) {
                    ForEach(qualities.indices, id: \.self) { i in Text(qualities[i].0).tag(qualities[i].1 ?? 0) }
                }
                Toggle("Rotate phone for fullscreen", isOn: pref(\.rotateToFullscreen))
                Toggle("Autoplay next video", isOn: Binding(get: { library.data.prefs.autoplay },
                                                           set: { PlayerModel.shared.setAutoplay($0) }))
                Toggle("Audio only carries over to next videos", isOn: Binding(
                    get: { library.data.prefs.audioOnlySticky },
                    set: { on in
                        let current = PlayerModel.shared.audioOnly
                        library.data.prefs.audioOnlySticky = on
                        library.data.prefs.audioOnly = on && current
                    }))
            } header: { Text("Player") }

            if library.data.prefs.visibleTabs.contains(.shorts) {
                Section {
                    Toggle("Autoplay", isOn: pref(\.autoplayShorts))
                    Toggle("Start muted if other audio is playing", isOn: pref(\.shortsMutedWhenOtherAudio))
                } header: { Text("Shorts") } footer: {
                    Text("Browsing never interrupts music or podcasts from other apps. Audio only switches over when you watch a video or unmute a Short.")
                }
            }

            Section {
                LabeledContent("Rumble ads", value: "None")
            } header: { Text("Skipping & ads") } footer: {
                Text("RumbleTube plays videos straight from Rumble's servers, so Rumble's ad player never loads. RumbleSkip handles sponsor reads inside videos.")
            }

            Section {
                NavigationLink { ReportProblemView().miniPlayerSpace() } label: {
                    Label("Report a problem", systemImage: "ladybug")
                }
            } footer: {
                Text("Shares a short log of what failed (pages, error codes). It never includes your password, cookies or what you searched for.")
            }

            Section("Data") {
                Button("Clear watch history", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear history and resume positions?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear", role: .destructive) { library.data.history = []; library.data.positions = [:] }
                    }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                Text("RumbleTube is an unofficial client. It reads public rumble.com pages; videos and channels belong to their creators.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .miniPlayerSpace()
    }
}

struct TabSettingsView: View {
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        List {
            Section {
                ForEach(library.data.prefs.normalizedTabs) { t in
                    HStack {
                        Label(t.tab.title, systemImage: t.tab.icon)
                        Spacer()
                        if t.tab.required {
                            Text("Always on").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Toggle("", isOn: Binding(
                                get: { t.enabled },
                                set: { on in
                                    var tabs = library.data.prefs.normalizedTabs
                                    if let i = tabs.firstIndex(where: { $0.tab == t.tab }) { tabs[i].enabled = on }
                                    library.data.prefs.tabs = tabs
                                }))
                            .labelsHidden()
                        }
                    }
                }
                .onMove { from, to in
                    var tabs = library.data.prefs.normalizedTabs
                    tabs.move(fromOffsets: from, toOffset: to)
                    library.data.prefs.tabs = tabs
                }
            } footer: {
                Text("Account holds Settings, so it always stays. Search and notifications are always at the top right. Drag the handles to reorder.")
            }
            Section {
                Button("Reset to default") { library.data.prefs.tabs = AppPreferences().tabs }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Tabs")
    }
}

struct GestureSettingsView: View {
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        Form {
            Section {
                ForEach(PlayerGesture.allCases) { g in
                    Picker(g.title, selection: Binding(
                        get: { library.data.prefs.action(for: g) },
                        set: { library.data.prefs.gestures[g.rawValue] = $0 })) {
                        ForEach(g.allowedActions) { Text($0.title).tag($0) }
                    }
                }
            } footer: {
                Text("Double-taps use the left, middle and right thirds of the video. Single tap shows or hides the controls.")
            }
            Section {
                Picker("Speed boost", selection: Binding(get: { library.data.prefs.boostRate },
                                                         set: { library.data.prefs.boostRate = $0 })) {
                    ForEach([1.5, 2.0, 2.5, 3.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                Picker("Rewind / fast-forward", selection: Binding(get: { library.data.prefs.seekSeconds },
                                                                  set: { library.data.prefs.seekSeconds = $0 })) {
                    ForEach(AppPreferences.seekChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }
            Section {
                Button("Reset to YouTube-style defaults") { library.data.prefs.gestures = [:] }
            }
        }
        .navigationTitle("Gestures")
    }
}


struct ReportProblemView: View {
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var library: LibraryStore
    @State private var entries: [String] = DiagLog.shared.entries
    @State private var fileURL: URL?

    private var header: [String: String] {
        let info = Bundle.main.infoDictionary
        return [
            "App": "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            "iOS": UIDevice.current.systemVersion,
            "Device": UIDevice.current.model,
            "Signed in": account.loggedIn ? "yes" : "no",
            "Tabs": library.data.prefs.visibleTabs.map(\.rawValue).joined(separator: ","),
            "Liquid Glass": library.data.prefs.liquidGlass ? "on" : "off",
        ]
    }

    var body: some View {
        List {
            Section {
                if let fileURL {
                    ShareLink(item: fileURL) { Label("Send report", systemImage: "square.and.arrow.up") }
                }
                Button { UIPasteboard.general.string = DiagLog.shared.report(header: header) } label: {
                    Label("Copy report", systemImage: "doc.on.doc")
                }
                Button("Clear log", role: .destructive) { DiagLog.shared.clear(); entries = []; fileURL = DiagLog.shared.reportFile(header: header) }
            } footer: {
                Text("Send it to whoever maintains your build (or paste it to Claude) to see exactly what Rumble changed.")
            }
            Section("Recent problems (\(entries.count))") {
                if entries.isEmpty { Text("Nothing has gone wrong yet.").foregroundStyle(.secondary) }
                ForEach(entries.reversed().prefix(150), id: \.self) { e in
                    Text(e).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Report a problem")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { entries = DiagLog.shared.entries; fileURL = DiagLog.shared.reportFile(header: header) }
    }
}
