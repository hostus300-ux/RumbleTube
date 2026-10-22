import SwiftUI

/// Who you're about to mute (or edit), plus the one-off "Show anyway" reveals for this session.
@MainActor
final class MuteUI: ObservableObject {
    static let shared = MuteUI()
    struct Request: Identifiable {
        enum Kind { case channel, user }
        var kind: Kind
        var path: String?
        var name: String
        var id: String { (path ?? name).lowercased() }
    }
    @Published var request: Request?
    /// Video ids and comment ids you chose to see anyway.
    @Published var revealed: Set<String> = []

    func muteChannel(_ v: VideoItem) {
        guard let n = v.channelName else { return }
        request = Request(kind: .channel, path: v.channelPath, name: n)
    }
    func muteChannel(_ c: ChannelRef) { request = Request(kind: .channel, path: c.path, name: c.name) }
    func muteUser(_ c: RumbleComment) { request = Request(kind: .user, path: c.authorPath, name: c.author) }
}

extension View {
    /// Presents the mute sheet. Only one host is active at a time (the app, or the full-screen player).
    func muteSheetHost(active: Bool) -> some View { modifier(MuteSheetHost(active: active)) }
}

private struct MuteSheetHost: ViewModifier {
    let active: Bool
    @ObservedObject private var ui = MuteUI.shared
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { active ? ui.request : nil }, set: { ui.request = $0 })) { r in
            MuteSheet(request: r).environmentObject(LibraryStore.shared)
        }
    }
}

struct MuteSheet: View {
    let request: MuteUI.Request
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var tag = ""

    private var existing: MutedEntry? { library.data.muteEntry(path: request.path, name: request.name) }
    private var what: String { request.kind == .channel ? "channel" : "user" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Reason (optional)", text: $tag)
                        .textInputAutocapitalization(.sentences)
                        .onChange(of: tag) { t in if t.count > MuteTag.maxLength { tag = String(t.prefix(MuteTag.maxLength)) } }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(MuteTag.suggestions, id: \.self) { s in
                                Button(s) { tag = s }.buttonStyle(.bordered).controlSize(.small)
                                    .tint(tag == s ? .rumbleGreen : .secondary)
                            }
                        }
                    }
                } header: {
                    Text("Tag")
                } footer: {
                    Text("Shown as a badge on their hidden \(request.kind == .channel ? "videos" : "comments"). \(tag.count)/\(MuteTag.maxLength)")
                }
                Section {
                    if !tag.isEmpty { HStack { Text("Preview"); Spacer(); MuteBadge(tag: MuteTag.clean(tag)) } }
                } footer: {
                    Text(request.kind == .channel
                         ? "Their videos still show up, collapsed and blurred, with a Show anyway button."
                         : "Their comments are collapsed, with a Show anyway button, and their replies to you don't show in Notifications.")
                }
                if let e = existing {
                    Section {
                        Button("Unmute \(e.name)", role: .destructive) { library.data.unmute(e.key); dismiss() }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Mute \(request.name)" : "Edit mute")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Mute" : "Save") {
                        let path = request.path ?? (request.kind == .user ? "/user/\(request.name)" : nil)
                        library.data.mute(path: path, name: request.name, tag: tag)
                        dismiss()
                    }.bold()
                }
            }
            .onAppear { tag = existing?.tag ?? "" }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The reason badge drawn over blurred thumbnails and hidden comments.
struct MuteBadge: View {
    let tag: String?
    var body: some View {
        Label(tag ?? "Muted", systemImage: "speaker.slash.fill")
            .font(.caption2.weight(.bold)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.black.opacity(0.75), in: Capsule())
            .foregroundStyle(.white)
    }
}

/// A muted channel's video, shrunk to a strip: blurred thumbnail + badge, no title or channel.
struct MutedVideoStrip: View {
    let item: VideoItem
    let entry: MutedEntry
    var compactWidth: CGFloat? = nil
    @ObservedObject private var ui = MuteUI.shared

    var body: some View {
        Group {
            if let w = compactWidth {
                VStack(alignment: .leading, spacing: 6) { thumb(width: w); text }.frame(width: w)
            } else {
                HStack(spacing: 10) { thumb(width: 120); text; Spacer(minLength: 0) }
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {}   // a hidden video shouldn't start playing by accident
        .contextMenu {
            Button { reveal() } label: { Label("Show anyway", systemImage: "eye") }
            Button { ui.request = .init(kind: .channel, path: item.channelPath, name: entry.name) } label: {
                Label("Edit mute", systemImage: "tag")
            }
            Button(role: .destructive) { LibraryStore.shared.data.unmute(entry.key) } label: {
                Label("Unmute channel", systemImage: "speaker.wave.2")
            }
        }
    }

    private func thumb(width: CGFloat) -> some View {
        Thumbnail(item: item)
            .blur(radius: 14).clipped()
            .overlay(Color.black.opacity(0.25))
            .overlay { MuteBadge(tag: entry.tag).padding(4) }
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Content from a channel you muted").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            Button("Show anyway") { reveal() }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
        }
    }

    private func reveal() { withAnimation(.easeInOut(duration: 0.2)) { _ = ui.revealed.insert(item.id) } }
}

/// Wraps any video card: muted channels collapse into a strip unless revealed.
struct MuteGate<Content: View>: View {
    let item: VideoItem
    var compactWidth: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    @EnvironmentObject var library: LibraryStore
    @ObservedObject private var ui = MuteUI.shared

    var body: some View {
        if let e = library.data.muteEntry(for: item), !ui.revealed.contains(item.id) {
            MutedVideoStrip(item: item, entry: e, compactWidth: compactWidth)
        } else {
            content()
        }
    }
}

/// Settings list of everyone you muted.
struct MutedListView: View {
    @EnvironmentObject var library: LibraryStore
    @ObservedObject private var ui = MuteUI.shared

    var body: some View {
        List {
            if library.data.muted.isEmpty {
                Text("Nobody muted. Long-press a video, or use the menu on a comment, to mute a channel or user.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(library.data.muted) { e in
                Button {
                    ui.request = .init(kind: e.key.hasPrefix("/c/") ? .channel : .user, path: e.key, name: e.name)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).foregroundStyle(.primary)
                            Text(e.key.hasPrefix("/c/") ? "Channel" : "User").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if e.tag != nil { MuteBadge(tag: e.tag) }
                    }
                }
            }
            .onDelete { idx in for i in idx { library.data.unmute(library.data.muted[i].key) } }
        }
        .navigationTitle("Muted")
    }
}
