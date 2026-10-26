import Foundation

/// Your own label for channels ("Politics", "Gaming"), with a colour. Tagged channels get a badge on their
/// thumbnails, and each tag becomes a tab in My Feed showing the followed channels that carry it.
struct ChannelTag: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// 0xRRGGBB
    var color: UInt32

    static let maxLength = 16
    static let palette: [UInt32] = [0xE74C3C, 0xF39C12, 0xF1C40F, 0x2ECC71, 0x1ABC9C, 0x3498DB, 0x9B59B6, 0xE84393, 0x95A5A6]

    static func clean(_ s: String) -> String? {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(maxLength))
    }
}

extension LibraryData {
    private static func tagKey(_ path: String) -> String { path.lowercased().components(separatedBy: "?")[0] }

    /// Tags on a channel, in the order you created them.
    func tags(for path: String?) -> [ChannelTag] {
        guard let path, !channelTags.isEmpty, let ids = taggedChannels[Self.tagKey(path)], !ids.isEmpty else { return [] }
        return channelTags.filter { ids.contains($0.id) }
    }

    @discardableResult
    mutating func createTag(name: String, color: UInt32) -> ChannelTag? {
        guard let n = ChannelTag.clean(name) else { return nil }
        if let existing = channelTags.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return existing }
        let t = ChannelTag(name: n, color: color)
        channelTags.append(t)
        return t
    }

    mutating func setTag(_ tag: ChannelTag, on channel: ChannelRef, _ on: Bool) {
        let k = Self.tagKey(channel.path)
        var ids = taggedChannels[k] ?? []
        if on { if !ids.contains(tag.id) { ids.append(tag.id) } } else { ids.removeAll { $0 == tag.id } }
        taggedChannels[k] = ids.isEmpty ? nil : ids
        if on { taggedNames[k] = channel.name }
    }

    mutating func deleteTag(_ id: UUID) {
        channelTags.removeAll { $0.id == id }
        for (k, v) in taggedChannels {
            let left = v.filter { $0 != id }
            taggedChannels[k] = left.isEmpty ? nil : left
        }
    }

    /// Channels carrying a tag (path + the name you saw when tagging).
    func channels(tagged id: UUID) -> [ChannelRef] {
        taggedChannels.filter { $0.value.contains(id) }.map { ChannelRef(path: $0.key, name: taggedNames[$0.key] ?? $0.key) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
