import SwiftUI

/// RumbleSkip panel: see segments, vote, mark new ones, link the YouTube upload.
struct SkipPanel: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var startText = ""
    @State private var endText = ""
    @State private var category: SkipCategory = .sponsor
    @State private var ytInput = ""
    @State private var ytOffset = ""
    @State private var message: String?
    @State private var busy = false

    private var hasServer: Bool { library.data.skip.server != nil }

    var body: some View {
        NavigationStack {
            Form {
                segmentsSection
                markSection
                youtubeSection
                Section {
                    NavigationLink("RumbleSkip settings") { SkipSettingsView() }
                } footer: {
                    Text("YouTube-linked segments come from SponsorBlock (sponsor.ajay.app), CC BY-NC-SA 4.0.")
                }
            }
            .navigationTitle("RumbleSkip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay(alignment: .bottom) {
                if let m = message {
                    Text(m).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.rumbleGreen, in: Capsule()).foregroundStyle(.black)
                        .padding(.bottom, 20).padding(.horizontal)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onTapGesture { message = nil }
                }
            }
            .animation(.easeInOut, value: message)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: sections

    private var segmentsSection: some View {
        Section {
            if player.segments.isEmpty {
                Text("Nobody has marked this video yet. Be the first below.").foregroundStyle(.secondary)
            }
            ForEach(player.segments) { seg in
                HStack(spacing: 10) {
                    Circle().fill(seg.category.color).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(seg.category.name)
                            Text(sourceTag(seg)).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                            if library.data.skip.action(for: seg.category) == .off {
                                Text("ignored").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text("\(TimeFormat.precise(seg.start)) → \(TimeFormat.precise(seg.end))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    iconButton("play.fill") { player.jump(to: seg) }
                    switch seg.source {
                    case .server:
                        iconButton("hand.thumbsup") { run { await player.vote(seg, up: true) } }
                        iconButton("hand.thumbsdown") { run { await player.vote(seg, up: false) } }
                    case .local:
                        iconButton("trash") { run { await player.vote(seg, up: false) } }
                    case .youtube:
                        EmptyView()
                    }
                }
            }
        } header: {
            Text("This video")
        } footer: {
            Text(player.skipStatus)
        }
    }

    private var markSection: some View {
        Section {
            HStack {
                TextField("Start (m:ss)", text: $startText).keyboardType(.numbersAndPunctuation).monospacedDigit()
                Button("Now") { startText = TimeFormat.precise(player.currentTime) }.buttonStyle(.bordered)
            }
            HStack {
                TextField("End (m:ss)", text: $endText).keyboardType(.numbersAndPunctuation).monospacedDigit()
                Button("Now") { endText = TimeFormat.precise(player.currentTime) }.buttonStyle(.bordered)
            }
            Picker("Category", selection: $category) {
                ForEach(SkipCategory.allCases) { c in Text(c.name).tag(c) }
            }
            HStack {
                Button("Preview") {
                    if let s = TimeFormat.parseClock(startText) { player.seek(to: max(0, s - 2)); player.resume() }
                }
                .buttonStyle(.bordered)
                Spacer()
                if hasServer {
                    Button("Submit") { submit(localOnly: false) }.buttonStyle(.borderedProminent).tint(.rumbleGreen)
                        .foregroundStyle(.black)
                }
                Button(hasServer ? "Save on device" : "Save") { submit(localOnly: true) }
                    .buttonStyle(.bordered)
            }
            .disabled(busy)
        } header: {
            Text("Mark a segment")
        } footer: {
            Text(hasServer ? "Submitted segments are shared with everyone using your RumbleSkip server."
                 : "No community server set — segments are saved on this device only. Add one in RumbleSkip settings.")
        }
    }

    private var youtubeSection: some View {
        Section {
            if let link = player.links.first {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Linked to \(link.youtubeID)").font(.subheadline)
                        Text(link.offset == 0 ? (link.local ? "On this device" : "Shared link")
                             : String(format: "Offset %.1fs", link.offset)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if link.local { Button("Unlink") { run { await player.unlinkYouTube(); return "Unlinked." } } }
                }
                if !library.data.skip.useYouTubeLinks {
                    Text("Using YouTube data is turned off in settings.").font(.caption).foregroundStyle(.secondary)
                }
            } else if let m = player.autoMatch, let yt = m.youtubeID, !m.rejected, m.confidence != .none {
                autoMatchRows(m, yt)
            } else {
                TextField("YouTube link or video ID", text: $ytInput).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Offset in seconds (optional)", text: $ytOffset).keyboardType(.numbersAndPunctuation)
                Button("Link") {
                    let off = Double(ytOffset.replacingOccurrences(of: ",", with: ".")) ?? 0
                    run { await player.linkYouTube(ytInput, offset: off) }
                }
                .disabled(ytInput.isEmpty || busy)
            }
        } header: {
            Text("Same video on YouTube?")
        } footer: {
            Text("Link the YouTube upload to pull its SponsorBlock skips. Offset = seconds the Rumble version runs ahead (+) or behind (−).")
        }
    }

    @ViewBuilder private func autoMatchRows(_ m: AutoLinkRecord, _ yt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(m.confidence == .differentEdit ? "Found on YouTube" : "Matched automatically", systemImage: "wand.and.stars")
                .font(.subheadline.weight(.semibold))
            Text(m.youtubeTitle ?? yt).font(.caption).lineLimit(2)
            Text(matchExplanation(m)).font(.caption).foregroundStyle(.secondary)
        }
        if m.confidence == .differentEdit {
            Button("Rumble's extra time is at the start") { run { await player.alignAutoMatch(extraAtStart: true) } }
            Button("Rumble's extra time is at the end") { run { await player.alignAutoMatch(extraAtStart: false) } }
        } else if m.confidence == .likely {
            Button("Lengths match — auto-skip these") { run { await player.alignAutoMatch(extraAtStart: false) } }
        }
        Button("Not this video", role: .destructive) { run { await player.rejectAutoMatch(); return "Won't use that match." } }
    }

    private func matchExplanation(_ m: AutoLinkRecord) -> String {
        let d = abs(m.lengthDifference ?? 0)
        let amount = d >= 120 ? "\(Int(d / 60)) min" : "\(Int(d)) sec"
        let which = (m.lengthDifference ?? 0) > 0 ? "shorter" : "longer"
        switch m.confidence {
        case .exact: return "Same length on both sites — SponsorBlock skips are applied automatically."
        case .likely: return "YouTube's version is \(amount) \(which), so skips show as buttons instead of skipping on their own."
        case .differentEdit: return "YouTube's version is \(amount) \(which) (a different edit), so its skip times won't line up until you say where the difference is. Use Preview on a segment to check."
        case .none: return ""
        }
    }

    // MARK: helpers

    private func sourceTag(_ s: SkipSegment) -> String {
        switch s.source {
        case .local: return "this device"
        case .youtube: return "via YouTube"
        case .server: return s.votes >= 0 ? "+\(s.votes)" : "\(s.votes)"
        }
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).frame(width: 30, height: 30) }
            .buttonStyle(.borderless)
    }

    private func submit(localOnly: Bool) {
        guard let s = TimeFormat.parseClock(startText), let e = TimeFormat.parseClock(endText) else {
            message = "Enter a start and end like 1:05 or 65.5"; return
        }
        let cat = category
        run {
            let m = await player.submitSegment(start: s, end: e, category: cat, localOnly: localOnly)
            if m.hasPrefix("Submitted") || m.hasPrefix("Saved") || m.hasPrefix("Someone") {
                startText = ""; endText = ""
            }
            return m
        }
    }

    private func run(_ work: @escaping () async -> String) {
        busy = true
        Task {
            let m = await work()
            busy = false
            message = m
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if message == m { message = nil }
        }
    }
}

/// RumbleSkip settings (also reachable from the Settings tab).
struct SkipSettingsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var server = ""

    var body: some View {
        Form {
            Section {
                ForEach(SkipCategory.allCases) { c in
                    Picker(selection: Binding(
                        get: { library.data.skip.action(for: c) },
                        set: { library.data.skip.actions[c.rawValue] = $0; PlayerModel.shared.settingsChanged() }
                    )) {
                        ForEach(SkipAction.allCases) { a in Text(a.name).tag(a) }
                    } label: {
                        HStack { Circle().fill(c.color).frame(width: 10, height: 10); Text(c.name) }
                    }
                }
            } header: { Text("Categories") }

            Section {
                Toggle("Show “Skipped” notice", isOn: binding(\.showNotice))
                Toggle("Use SponsorBlock for linked YouTube videos", isOn: binding(\.useYouTubeLinks))
                Toggle("Find YouTube copies automatically", isOn: binding(\.autoMatchYouTube))
                    .disabled(!library.data.skip.useYouTubeLinks)
            } header: { Text("Behaviour") } footer: {
                Text("When a video has no skips yet, RumbleTube searches YouTube for the same title from your phone and uses its SponsorBlock data if the title, channel and length match.")
            }

            Section {
                TextField("https://rumbleskip-api.you.workers.dev", text: $server)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(saveServer)
                Button("Save server", action: saveServer).disabled(server == library.data.skip.serverURL)
            } header: {
                Text("Community server")
            } footer: {
                Text("Leave empty to keep segments on this device only. Use the same server as the RumbleSkip browser extension to share skips between your phone and computer.")
            }

            Section {
                LabeledContent("Skips", value: "\(library.data.skipStats.skips)")
                LabeledContent("Time saved", value: TimeFormat.clock(library.data.skipStats.secondsSaved))
                LabeledContent("Anonymous ID", value: String(library.data.skip.userID.prefix(8)) + "…")
            } header: { Text("Your stats") }
        }
        .navigationTitle("RumbleSkip")
        .onAppear { server = library.data.skip.serverURL }
    }

    private func binding(_ key: WritableKeyPath<SkipSettings, Bool>) -> Binding<Bool> {
        Binding(get: { library.data.skip[keyPath: key] },
                set: { library.data.skip[keyPath: key] = $0; PlayerModel.shared.settingsChanged() })
    }

    private func saveServer() {
        let s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty || s.hasPrefix("https://") || s.hasPrefix("http://") else { return }
        library.data.skip.serverURL = s
        PlayerModel.shared.settingsChanged()
    }
}
