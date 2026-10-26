import SwiftUI

/// Which channel you're tagging (one sheet for the whole app).
@MainActor
final class TagUI: ObservableObject {
    static let shared = TagUI()
    @Published var channel: ChannelRef?
    func tag(_ c: ChannelRef) { channel = c }
    func tag(_ v: VideoItem) { if let c = v.channel { channel = c } }
}

extension ChannelRef { var tagSheetID: String { id } }

extension View {
    /// Presents the tag sheet; like the mute sheet, only one host is active at a time.
    func tagSheetHost(active: Bool) -> some View { modifier(TagSheetHost(active: active)) }
}

private struct TagSheetHost: ViewModifier {
    let active: Bool
    @ObservedObject private var ui = TagUI.shared
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { active ? ui.channel : nil }, set: { ui.channel = $0 })) { c in
            TagChannelSheet(channel: c).environmentObject(LibraryStore.shared)
        }
    }
}

/// Pick tags for a channel, or make a new one with a colour.
struct TagChannelSheet: View {
    let channel: ChannelRef
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newColor = ChannelTag.palette[5]

    private var current: Set<UUID> { Set(library.data.tags(for: channel.path).map(\.id)) }

    var body: some View {
        NavigationStack {
            Form {
                if !library.data.channelTags.isEmpty {
                    Section("Your tags") {
                        ForEach(library.data.channelTags) { t in
                            Button {
                                library.data.setTag(t, on: channel, !current.contains(t.id))
                            } label: {
                                HStack {
                                    TagBadge(tag: t)
                                    Spacer()
                                    if current.contains(t.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    TextField("New tag, e.g. Politics", text: $newName)
                        .onChange(of: newName) { n in if n.count > ChannelTag.maxLength { newName = String(n.prefix(ChannelTag.maxLength)) } }
                    TagColorPicker(color: $newColor)
                    Button {
                        if let t = library.data.createTag(name: newName, color: newColor) {
                            library.data.setTag(t, on: channel, true)
                            newName = ""
                        }
                    } label: { Label("Add tag", systemImage: "plus.circle.fill") }
                    .disabled(ChannelTag.clean(newName) == nil)
                } header: {
                    Text("New tag")
                } footer: {
                    Text("Tagged channels get a coloured badge on their videos. Each tag is also a tab in My Feed with the channels you follow that carry it.")
                }
            }
            .navigationTitle("Tag \(channel.name)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct TagColorPicker: View {
    @Binding var color: UInt32
    var body: some View {
        HStack(spacing: 10) {
            ForEach(ChannelTag.palette, id: \.self) { c in
                Circle().fill(Color(hex: c)).frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.primary, lineWidth: color == c ? 2.5 : 0).padding(-3))
                    .onTapGesture { color = c }
                    .accessibilityAddTraits(color == c ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// A coloured tag label.
struct TagBadge: View {
    let tag: ChannelTag
    var small = false
    var body: some View {
        Text(tag.name)
            .font(small ? .caption2.weight(.bold) : .footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, small ? 6 : 9).padding(.vertical, small ? 2 : 4)
            .background(Color(hex: tag.color), in: Capsule())
            .foregroundStyle(.white)
    }
}

/// Tag badges over a thumbnail (first tag, plus "+n").
struct ThumbnailTags: View {
    let tags: [ChannelTag]
    var body: some View {
        if let first = tags.first {
            HStack(spacing: 3) {
                TagBadge(tag: first, small: true)
                if tags.count > 1 {
                    Text("+\(tags.count - 1)").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 2)
            .padding(6)
        }
    }
}

/// Settings: rename, recolour or delete tags.
struct ChannelTagsSettings: View {
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        List {
            if library.data.channelTags.isEmpty {
                Text("No tags yet. Long-press a video or use ⋯ on a channel page and choose Tag channel.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach($library.data.channelTags) { $tag in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Name", text: Binding(get: { tag.name },
                                                        set: { tag.name = ChannelTag.clean($0) ?? tag.name }))
                        Spacer()
                        Text("\(library.data.channels(tagged: tag.id).count) channels").font(.caption).foregroundStyle(.secondary)
                    }
                    TagColorPicker(color: $tag.color)
                }
            }
            .onDelete { idx in for i in idx { library.data.deleteTag(library.data.channelTags[i].id) } }
        }
        .navigationTitle("Channel tags")
    }
}
