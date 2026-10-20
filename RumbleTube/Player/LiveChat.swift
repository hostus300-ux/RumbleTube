import ImageIO
import SwiftUI
import UIKit

/// Streams a live chat (server-sent events) and sends messages as the signed-in user.
@MainActor
final class LiveChatModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var connected = false
    @Published var error: String?
    @Published var sending = false
    /// Rumble emotes for this chat (site-wide + channel/subscriber packs), keyed by lowercased name.
    @Published private(set) var emotes: [String: ChatEmote] = [:]
    private var task: Task<Void, Never>?
    private(set) var config: ChatConfig?
    private let maxMessages = 300

    func start(_ c: ChatConfig) {
        guard c != config || task == nil else { return }
        stop()
        config = c
        messages = []
        emotes = [:]
        Task { [weak self] in await self?.loadEmotes(c) }
        task = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                await self?.run(c)
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)   // reconnect with backoff
                delay = min(delay * 2, 20)
            }
        }
    }

    private func loadEmotes(_ c: ChatConfig) async {
        var r = ChatEmotes.request(chatID: c.chatID)
        r.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        guard let res = try? await RumbleHTTP.session.data(for: r), config == c else { return }
        let found = ChatEmotes.parse(res.0)
        if !found.isEmpty { emotes = found }
    }

    func stop() {
        task?.cancel(); task = nil
        connected = false
    }

    private func run(_ c: ChatConfig) async {
        var req = URLRequest(url: LiveChatParser.streamURL(c))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 300
        do {
            let (bytes, resp) = try await RumbleHTTP.session.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                DiagLog.shared.request(req.url, status: (resp as? HTTPURLResponse)?.statusCode)
                error = "Chat unavailable (\((resp as? HTTPURLResponse)?.statusCode ?? 0))"; return
            }
            connected = true; error = nil
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let e = LiveChatParser.parseEvent(Data(json.utf8)) else { continue }
                apply(e)
            }
        } catch {
            if !(error is CancellationError) { self.error = "Reconnecting to chat…" }
        }
        connected = false
    }

    private func apply(_ e: (type: String, messages: [ChatMessage], deletedIDs: [String])) {
        if e.type == "init" { messages = [] }
        if !e.deletedIDs.isEmpty { let gone = Set(e.deletedIDs); messages.removeAll { gone.contains($0.id) } }
        let known = Set(messages.map(\.id))
        messages += e.messages.filter { !known.contains($0.id) }
        if messages.count > maxMessages { messages.removeFirst(messages.count - maxMessages) }
    }

    /// Paid rant from the Rumble Wallet. Returns an error message, or nil when Rumble accepted it.
    func sendRant(_ text: String, cents: Int) async -> String? {
        guard let c = config else { return "Chat isn't connected." }
        sending = true
        defer { sending = false }
        var r = LiveChatParser.rantRequest(c, text: text, cents: cents)
        r.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await RumbleHTTP.session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return nil }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return ((obj?["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? "Rumble didn't accept the rant (\(code))."
        } catch { return error.localizedDescription }
    }

    func send(_ text: String) async -> Bool {
        guard let c = config, !text.isEmpty else { return false }
        sending = true
        defer { sending = false }
        var r = LiveChatParser.sendRequest(c, text: text)
        r.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await RumbleHTTP.session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return true }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = ((obj?["errors"] as? [[String: Any]])?.first?["message"] as? String)
            error = msg ?? "Couldn't send (\(code))"
        } catch { self.error = error.localizedDescription }
        return false
    }
}

struct LiveChatView: View {
    @ObservedObject var chat: LiveChatModel
    var videoURL: URL? = nil
    var channel: ChannelRef? = nil
    @State private var showRant = false
    @State private var showGift = false
    @EnvironmentObject var account: AccountStore
    @State private var draft = ""
    @State private var showLogin = false
    @State private var pinnedToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if chat.messages.isEmpty {
                            Text(chat.connected ? "Say hi — chat is quiet." : "Connecting to chat…")
                                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                        }
                        ForEach(chat.messages) { m in ChatRow(message: m, emotes: chat.emotes).id(m.id) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .onChange(of: chat.messages.last?.id) { id in
                    guard pinnedToBottom, let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
                }
                .simultaneousGesture(DragGesture().onChanged { v in if v.translation.height > 20 { pinnedToBottom = false } })
                .overlay(alignment: .bottom) {
                    if !pinnedToBottom {
                        Button {
                            pinnedToBottom = true
                            if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                        } label: {
                            Label("Latest", systemImage: "arrow.down").font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                        }
                        .glassCapsule()
                        .padding(.bottom, 8)
                    }
                }
            }
            if let e = chat.error { Text(e).font(.caption2).foregroundStyle(.secondary).padding(.vertical, 2) }
            Divider()
            if account.loggedIn {
                HStack(spacing: 8) {
                    ChannelAvatar(name: account.username ?? "You", url: account.avatarURL, size: 32)
                    TextField("Add a message…", text: $draft, axis: .vertical)
                        .lineLimit(1...3)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                        .submitLabel(.send)
                        .onSubmit(send)
                    if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button(action: send) {
                            Image(systemName: "paperplane.fill").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                        }
                        .disabled(chat.sending)
                    } else {
                        Button { showRant = true } label: {
                            Image(systemName: "dollarsign").font(.body.weight(.bold)).foregroundStyle(Color.rumbleGreen)
                                .frame(width: 38, height: 38).glassCircle(tint: Color.secondary.opacity(0.25))
                        }
                        .accessibilityLabel("Send a Rant")
                        .disabled(chat.config == nil)
                        Button { showGift = true } label: {
                            Image(systemName: "gift").font(.body.weight(.bold)).foregroundStyle(Color(hex: 0xD9474B))
                                .frame(width: 38, height: 38).glassCircle(tint: Color.secondary.opacity(0.25))
                        }
                        .accessibilityLabel("Gift subs")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .sheet(isPresented: $showRant) {
                    if let c = chat.config {
                        RantSheet(chat: chat, config: c, videoURL: videoURL).environmentObject(account)
                    }
                }
                .sheet(isPresented: $showGift) { GiftSubsSheet(channel: channel, videoURL: videoURL) }
            } else {
                Button("Sign in to chat") { showLogin = true }.font(.subheadline.weight(.semibold)).padding(10)
            }
        }
        .sheet(isPresented: $showLogin) { LoginView().environmentObject(account) }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            if await chat.send(t) { draft = ""; pinnedToBottom = true }
        }
    }
}

struct ChatRow: View {
    let message: ChatMessage
    var emotes: [String: ChatEmote] = [:]

    var body: some View {
        if let cents = message.rantCents {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ChannelAvatar(name: message.username, url: message.avatar, size: 22)
                    Text(message.username).font(.caption.weight(.bold))
                    Spacer()
                    Text(String(format: "$%.2f", Double(cents) / 100)).font(.caption.weight(.heavy))
                }
                ChatText(segments: ChatEmotes.segments(message.text, emotes: emotes), font: .subheadline)
            }
            .padding(10)
            .background(rantColor(cents).opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(cents >= 2000 || cents < 200 ? Color.white : Color.black)
        } else {
            HStack(alignment: .top, spacing: 8) {
                ChannelAvatar(name: message.username, url: message.avatar, size: 22)
                ChatText(segments: ChatEmotes.segments(message.text, emotes: emotes), font: .subheadline,
                         lead: Text(message.username + (message.badges.contains("verified") ? " ✓" : ""))
                            .font(.caption.weight(.bold))
                            .foregroundColor(message.isChannel ? Color.rumbleGreen : (Color(hexString: message.color) ?? Color.secondary)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Rumble's rant tiers: $1 blue, $2 green, $5 yellow, $10 orange, $20 pink, $50 purple, $100+ red.
    private func rantColor(_ c: Int) -> Color {
        switch c {
        case ..<200: return Color(hex: 0x4A90E2)
        case ..<500: return Color(hex: 0xB8E986)
        case ..<1000: return Color(hex: 0xF8E71C)
        case ..<2000: return Color(hex: 0xF5A623)
        case ..<5000: return Color(hex: 0xBD10E0)
        case ..<10000: return Color(hex: 0x9013FE)
        default: return Color(hex: 0xD0021B)
        }
    }
}

extension Color {
    init?(hexString: String?) {
        guard var s = hexString?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}


// MARK: - Message text with inline emote images

/// Wraps words and emote images like a paragraph. Emotes are drawn at the line height (bigger when a
/// message is only emotes, like Rumble's site).
struct ChatText: View {
    let segments: [ChatSegment]
    var font: Font = .subheadline
    var lead: Text? = nil

    private enum Piece: Hashable { case word(String), emote(ChatEmote) }

    private var pieces: [Piece] {
        segments.flatMap { seg -> [Piece] in
            switch seg {
            case .emote(let e): return [.emote(e)]
            case .text(let t):
                // keep the spaces with the words so wrapping looks natural
                var out: [Piece] = []
                var cur = ""
                for ch in t {
                    cur.append(ch)
                    if ch == " " { out.append(.word(cur)); cur = "" }
                }
                if !cur.isEmpty { out.append(.word(cur)) }
                return out
            }
        }
    }

    private var emoteOnly: Bool {
        segments.allSatisfy { if case .text(let t) = $0 { return t.trimmingCharacters(in: .whitespaces).isEmpty }; return true }
    }

    var body: some View {
        if !segments.contains(where: { if case .emote = $0 { return true }; return false }) {
            // plain text: one Text so it wraps and selects normally
            let plain = Text(segments.map { seg -> String in if case .text(let t) = seg { return t }; return "" }.joined()).font(font)
            if let lead { lead + Text("  ") + plain } else { plain }
        } else {
            FlowLayout(spacing: 0, lineSpacing: 2) {
                if let lead { lead.padding(.trailing, 6) }
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                    switch p {
                    case .word(let w): Text(w).font(font)
                    case .emote(let e):
                        EmoteImage(url: e.url, size: emoteOnly ? 36 : 22)
                            .padding(.horizontal, 1)
                            .accessibilityLabel(":\(e.name):")
                    }
                }
            }
        }
    }
}

/// Minimal flow layout: places children left-to-right and wraps to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, width), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // first pass: work out lines so items can be centred vertically on each line
        var lines: [[(LayoutSubview, CGSize)]] = [[]]
        var x: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > bounds.width { lines.append([]); x = 0 }
            lines[lines.count - 1].append((s, sz))
            x += sz.width + spacing
        }
        var y = bounds.minY
        for line in lines {
            let h = line.map(\.1.height).max() ?? 0
            var lx = bounds.minX
            for (s, sz) in line {
                s.place(at: CGPoint(x: lx, y: y + (h - sz.height) / 2), proposal: ProposedViewSize(sz))
                lx += sz.width + spacing
            }
            y += h + lineSpacing
        }
    }
}

/// Loads an emote (PNG or animated GIF) once and keeps it in memory.
struct EmoteImage: View {
    let url: String
    var size: CGFloat = 22
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { AnimatedImageView(image: image) } else { Color.clear }
        }
        .frame(width: size * aspect, height: size)
        .task(id: url) { image = await EmoteCache.shared.image(url) }
    }

    private var aspect: CGFloat {
        guard let i = image, i.size.height > 0 else { return 1 }
        return min(3, max(0.5, i.size.width / i.size.height))
    }
}

private struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }
    func updateUIView(_ v: UIImageView, context: Context) {
        if v.image !== image { v.image = image; if image.images != nil { v.startAnimating() } }
    }
}

actor EmoteCache {
    static let shared = EmoteCache()
    private var images: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(_ url: String) async -> UIImage? {
        if let i = images[url] { return i }
        if let t = inFlight[url] { return await t.value }
        let t = Task<UIImage?, Never> {
            guard let u = URL(string: url) else { return nil }
            var r = URLRequest(url: u, cachePolicy: .returnCacheDataElseLoad)
            r.setValue(RumbleHTTP.userAgent, forHTTPHeaderField: "User-Agent")
            guard let res = try? await URLSession.shared.data(for: r) else { return nil }
            return EmoteCache.decode(res.0)
        }
        inFlight[url] = t
        let img = await t.value
        inFlight[url] = nil
        if let img { images[url] = img }
        return img
    }

    /// GIFs become animated UIImages; everything else decodes normally.
    nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let n = CGImageSourceGetCount(src)
        guard n > 1 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var total: Double = 0
        for i in 0..<min(n, 120) {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            total += d < 0.02 ? 0.1 : d
        }
        return frames.isEmpty ? UIImage(data: data) : UIImage.animatedImage(with: frames, duration: total)
    }
}
