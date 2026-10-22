import SwiftUI

/// Follow / unfollow for a channel, kept in sync with your Rumble account when signed in.
/// Not following: a clear green Follow button. Following: a small "Following ✓" that asks before unfollowing,
/// so it can't be hit by accident.
struct FollowControl: View {
    let channel: ChannelRef
    /// Channel page header, when known (has Rumble's id and follow state).
    var header: ChannelHeader? = nil
    var fullWidth = false

    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var account: AccountStore
    @ObservedObject private var feed = MyFeedModel.shared
    @State private var override: Bool?
    @State private var busy = false
    @State private var confirm = false
    @State private var error: String?

    private var following: Bool {
        if let override { return override }
        if account.loggedIn, let h = header?.followingOnRumble { return h || library.data.isFollowing(channel.path) }
        return library.data.isFollowing(channel.path) || feed.channels.contains { $0.id == channel.id }
    }

    var body: some View {
        VStack(alignment: fullWidth ? .center : .trailing, spacing: 4) {
            if following {
                Button { confirm = true } label: {
                    Label("Following", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.4)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .frame(maxWidth: fullWidth ? .infinity : nil, alignment: fullWidth ? .leading : .trailing)
                .padding(.horizontal, fullWidth ? 12 : 0)
            } else {
                Button { Task { await set(true) } } label: {
                    Text("Follow").font(.subheadline.weight(.semibold)).frame(maxWidth: fullWidth ? .infinity : nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.rumbleGreen)
                .foregroundStyle(Color.black)
                .disabled(busy)
                .padding(.horizontal, fullWidth ? 12 : 0)
            }
            if let error { Text(error).font(.caption2).foregroundStyle(.red) }
        }
        .confirmationDialog("Unfollow \(channel.name)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Unfollow", role: .destructive) { Task { await set(false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their videos will stop showing in My Feed.")
        }
    }

    private func set(_ follow: Bool) async {
        busy = true
        defer { busy = false }
        if account.loggedIn {
            var h = header
            if h?.rumbleID == nil { h = (try? await RumbleService.shared.channel(channel.path))?.channel }
            if let id = h?.rumbleID {
                do {
                    try await account.setFollow(id: id, type: h?.rumbleType ?? "channel", follow: follow)
                    error = nil
                } catch {
                    self.error = "Couldn't update Rumble. Try again."
                    return
                }
            }
        }
        if library.data.isFollowing(channel.path) != follow { library.data.toggleFollow(channel) }
        override = follow
        if account.loggedIn { await MyFeedModel.shared.refreshChannels(force: true) }
    }
}
