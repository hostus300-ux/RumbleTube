import SwiftUI
import WebKit

// MARK: - Rumble pages in a sheet (signed-in cookies, Rumble's own checkout / upload)

struct RumbleWebSheet: View {
    let title: String
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RumbleWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct RumbleWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // same sign-in as the Rumble login sheet
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = RumbleHTTP.userAgent
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate {
        // Checkout / sign-in pop-ups open in the same view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}

// MARK: - Send a Rant

struct RantSheet: View {
    @ObservedObject var chat: LiveChatModel
    let config: ChatConfig
    let videoURL: URL?
    @EnvironmentObject var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var level = 0.0
    @State private var text = ""
    @State private var confirm = false
    @State private var showWeb = false
    @State private var result: String?

    private var levels: [RantLevel] { config.rantLevels.isEmpty ? RantLevel.defaults : config.rantLevels }
    private var tier: RantLevel { levels[min(levels.count - 1, max(0, Int(level.rounded())))] }
    private let maxChars = 200

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    card
                    HStack {
                        Text("The rant will stick for ") + Text(tier.durationText).bold()
                        Spacer()
                        Text("\(text.count)/\(maxChars)").monospacedDigit()
                            .foregroundStyle(text.isEmpty || text.count > maxChars ? Color.red : Color.secondary)
                    }
                    .font(.subheadline)
                    VStack(spacing: 6) {
                        Slider(value: $level, in: 0...Double(levels.count - 1), step: 1)
                            .tint(Color(hex: tier.colorHex))
                        HStack {
                            Text("$\(levels.first?.dollars ?? 1)")
                            Spacer()
                            Text("$\(levels.last?.dollars ?? 500)")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

                    Divider()
                    Button { confirm = true } label: {
                        Label("Pay with Rumble Wallet", systemImage: "wallet.pass")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .overlay(Capsule().stroke(Color.primary.opacity(0.6), lineWidth: 1.5))
                    .disabled(!canSend || chat.sending)
                    .opacity(canSend ? 1 : 0.5)

                    if videoURL != nil {
                        Button { showWeb = true } label: {
                            Label("Pay with Apple Pay on Rumble", systemImage: "apple.logo")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        .overlay(Capsule().stroke(Color.primary.opacity(0.6), lineWidth: 1.5))
                    }
                    if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
                    Text("Rants are paid to the creator through Rumble. Apple Pay opens Rumble's own rant checkout for this stream.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationTitle("Send a Rant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Send a $\(tier.dollars) rant?", isPresented: $confirm) {
                Button("Send $\(tier.dollars)") { send() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("$\(tier.dollars).00 will be charged to your Rumble Wallet and your message pinned for \(tier.durationText).")
            }
            .sheet(isPresented: $showWeb) {
                if let videoURL { RumbleWebSheet(title: "Rant", url: videoURL) }
            }
        }
        .presentationDetents([.large])
    }

    private var canSend: Bool { account.loggedIn && !text.trimmingCharacters(in: .whitespaces).isEmpty && text.count <= maxChars }

    private var card: some View {
        let fg: Color = tier.darkText ? .black : .white
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ChannelAvatar(name: account.username ?? "You", url: account.avatarURL, size: 36)
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.username ?? "You").font(.headline)
                    Text("$\(tier.dollars)").font(.title3.weight(.heavy))
                }
            }
            .padding(14)
            TextField("Add a message…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.18))
        }
        .foregroundStyle(fg)
        .background(Color(hex: tier.colorHex), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .animation(.easeInOut(duration: 0.15), value: tier)
    }

    private func send() {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cents = tier.cents
        Task {
            if let err = await chat.sendRant(msg, cents: cents) { result = err }
            else { dismiss() }
        }
    }
}

// MARK: - Gift subscriptions

struct GiftSubsSheet: View {
    let channel: ChannelRef?
    let videoURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var showWeb = false

    private let options = [1, 5, 10, 20, 50]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let c = channel {
                        HStack(spacing: 14) {
                            ChannelAvatar(name: c.name, url: c.avatar, size: 60)
                            Text(c.name).font(.title2.weight(.bold)).lineLimit(2)
                        }
                        Divider()
                    }
                    Text("Gift a 1 month channel subscription to the community").font(.title3.weight(.bold))
                    ForEach(options, id: \.self) { n in
                        Button { showWeb = true } label: {
                            HStack {
                                Text(n == 1 ? "Gift 1 Sub" : "Gift \(n) Subs").font(.headline)
                                Spacer()
                                Label("Continue", systemImage: "gift.fill")
                                    .font(.subheadline.weight(.bold))
                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                    .background(Color(hex: 0xD9474B), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            .padding(16)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.4)))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Gift checkout happens on Rumble, where you'll see the price for this channel and can pay with Apple Pay or Rumble Wallet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationTitle("Gift subs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showWeb) {
                if let videoURL { RumbleWebSheet(title: "Gift subs", url: videoURL) }
            }
        }
    }
}

// MARK: - Create tab

struct CreateScreen: View {
    @EnvironmentObject var account: AccountStore
    @Environment(\.openURL) private var openURL
    @State private var showUpload = false
    @State private var showLogin = false

    static let studioAppStore = URL(string: "https://apps.apple.com/app/id6472735205")!
    static let studioLink = URL(string: "https://studio.rumble.com/")!

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                option("Upload a video", "Pick a video from your phone and publish it to your channel.", "square.and.arrow.up", .rumbleGreen) {
                    if account.loggedIn { showUpload = true } else { showLogin = true }
                }
                option("Go live", "Stream with the Rumble Studio app. If it isn't installed, the App Store opens to it.", "dot.radiowaves.left.and.right", .red) {
                    goLive()
                }
            }
            .padding(16)
        }
        .appHeader("Create")
        .miniPlayerSpace()
        .sheet(isPresented: $showUpload) {
            RumbleWebSheet(title: "Upload", url: URL(string: "https://rumble.com/upload.php")!)
        }
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(account) }
    }

    private func option(_ title: String, _ detail: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56).background(color, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(16)
            .glassCard(18, interactive: true)
            .background {
                if !GlassUI.enabled { RoundedRectangle(cornerRadius: 18).fill(Color.secondary.opacity(0.12)) }
            }
        }
        .buttonStyle(.plain)
    }

    /// Open Rumble Studio if it's installed (via its link), otherwise its App Store page.
    private func goLive() {
        UIApplication.shared.open(Self.studioLink, options: [.universalLinksOnly: true]) { opened in
            if !opened { UIApplication.shared.open(Self.studioAppStore) }
        }
    }
}
