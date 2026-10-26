import SwiftUI

/// Settings: your Rumble account's own settings pages, plus RumbleTube's settings for the app itself.
struct RumbleSettingsScreen: View {
    @EnvironmentObject var account: AccountStore
    @State private var page: RumblePage?
    @State private var showLogin = false

    struct RumblePage: Identifiable {
        let title: String
        let path: String
        let icon: String
        var id: String { path }
        var url: URL { URL(string: path.hasPrefix("http") ? path : "https://rumble.com" + path)! }
    }

    /// The account pages from rumble.com's own account menu.
    private let pages: [RumblePage] = [
        .init(title: "Account settings", path: "/account/settings", icon: "person.crop.circle"),
        .init(title: "Profile", path: "/account/profile", icon: "person.text.rectangle"),
        .init(title: "Privacy", path: "/account/privacy", icon: "hand.raised"),
        .init(title: "Notification settings", path: "/account/notifications", icon: "bell"),
        .init(title: "Dashboard", path: "/account/dashboard", icon: "chart.bar"),
        .init(title: "My content", path: "/account/content", icon: "play.rectangle.on.rectangle"),
        .init(title: "Manage subscriptions", path: "/account/recurring-subs", icon: "creditcard"),
        .init(title: "Earnings & payouts", path: "/account/earnings", icon: "dollarsign.circle"),
        .init(title: "Rumble Wallet", path: "/account/wallet", icon: "wallet.pass"),
        .init(title: "Locals Connect", path: "/locals-connect", icon: "link"),
    ]

    var body: some View {
        Form {
            Section {
                NavigationLink(value: AppRoute.appSettings) {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3").font(.body.weight(.semibold))
                            .frame(width: 30, height: 30).background(Color.rumbleGreen, in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(.black)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("RumbleTube").font(.body.weight(.semibold))
                            Text("This app: RumbleSkip, gestures, tabs, look, player, backup").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                if account.loggedIn {
                    ForEach(pages) { p in
                        Button { page = p } label: {
                            HStack {
                                Label(p.title, systemImage: p.icon).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Button { UIApplication.shared.open(URL(string: "https://studio.rumble.com/")!) } label: {
                        Label("Rumble Studio", systemImage: "video.badge.plus").foregroundStyle(.primary)
                    }
                } else {
                    Button("Sign in to Rumble") { showLogin = true }
                }
            } header: {
                Text("Rumble account\(account.username.map { " · \($0)" } ?? "")")
            } footer: {
                Text("These are Rumble's own settings pages, opened inside the app with your sign-in.")
            }
        }
        .navigationTitle("Settings")
        .sheet(item: $page) { p in RumbleWebSheet(title: p.title, url: p.url) }
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(account) }
        .miniPlayerSpace()
    }
}
