import Foundation

/// A channel or commenter you muted, with an optional short reason shown as a badge ("Content spam").
struct MutedEntry: Codable, Hashable, Identifiable {
    /// "/c/name" or "/user/name", lowercased
    var key: String
    var name: String
    var tag: String?
    var mutedAt: Date = Date()
    var id: String { key }
}

enum MuteTag {
    static let maxLength = 20
    static let suggestions = ["Spam", "Clickbait", "Not interested", "Off-topic", "Rage bait", "Repetitive"]

    /// Trimmed, single line, at most `maxLength` characters; nil when empty.
    static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !one.isEmpty else { return nil }
        return String(one.prefix(maxLength))
    }

    static func key(path: String?, name: String?) -> String? {
        if let p = path?.lowercased(), p.hasPrefix("/c/") || p.hasPrefix("/user/") {
            return String(p.split(separator: "?")[0])
        }
        if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return "/user/" + n.lowercased() }
        return nil
    }
}

extension LibraryData {
    func muteEntry(path: String?, name: String?) -> MutedEntry? {
        guard !muted.isEmpty else { return nil }
        let keys = [MuteTag.key(path: path, name: nil), MuteTag.key(path: nil, name: name),
                    name.map { "/c/" + $0.lowercased() }].compactMap { $0 }
        return muted.first { keys.contains($0.key) }
    }

    func muteEntry(for v: VideoItem) -> MutedEntry? { muteEntry(path: v.channelPath, name: v.channelName) }

    mutating func mute(path: String?, name: String, tag: String?) {
        guard let key = MuteTag.key(path: path, name: name) else { return }
        muted.removeAll { $0.key == key }
        muted.insert(MutedEntry(key: key, name: name, tag: MuteTag.clean(tag)), at: 0)
    }

    mutating func unmute(_ key: String) { muted.removeAll { $0.key == key } }
}
