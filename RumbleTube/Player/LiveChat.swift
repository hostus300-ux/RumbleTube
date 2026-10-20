import SwiftUI

/// Streams a live chat (server-sent events) and sends messages as the signed-in user.
@MainActor
final class LiveChatModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var connected = false
    @Published var error: String?
    @Published var sending = false
    private var task: Task<Void, Never>?
    private(set) var config: ChatConfig?
    private let maxMessages = 300

    func start(_ c: ChatConfig) {
        guard c != config || task == nil else { return }
        stop()
        config = c
        messages = []
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
                        ForEach(chat.messages) { m in ChatRow(message: m).id(m.id) }
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

    var body: some View {
        if let cents = message.rantCents {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ChannelAvatar(name: message.username, url: message.avatar, size: 22)
                    Text(message.username).font(.caption.weight(.bold))
                    Spacer()
                    Text(String(format: "$%.2f", Double(cents) / 100)).font(.caption.weight(.heavy))
                }
                Text(message.text).font(.subheadline)
            }
            .padding(10)
            .background(rantColor(cents).opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(cents >= 2000 || cents < 200 ? Color.white : Color.black)
        } else {
            HStack(alignment: .top, spacing: 8) {
                ChannelAvatar(name: message.username, url: message.avatar, size: 22)
                (Text(message.username + (message.badges.contains("verified") ? " ✓" : "") + "  ")
                    .font(.caption.weight(.bold))
                    .foregroundColor(message.isChannel ? Color.rumbleGreen : (Color(hexString: message.color) ?? Color.secondary))
                 + Text(message.text).font(.subheadline))
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
