import SwiftUI
import WebKit

/// "Join" (channel memberships) and "Tip" (Rumble Wallet QR) — shown only when the creator set them up.
struct CreatorButtons: View {
    let channel: ChannelRef
    var joinable: Bool
    var tipID: String?
    @State private var showJoin = false
    @State private var showTip = false

    var body: some View {
        if joinable || tipID != nil {
            HStack(spacing: 8) {
                if joinable {
                    Button { showJoin = true } label: {
                        Label("Join", systemImage: "star.fill").font(.footnote.weight(.bold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.rumbleRed, in: Capsule()).foregroundStyle(.white)
                    }
                }
                if tipID != nil {
                    Button { showTip = true } label: {
                        Label("Tip", systemImage: "qrcode").font(.footnote.weight(.bold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.18), in: Capsule()).foregroundStyle(.primary)
                    }
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showJoin) {
                // Memberships are sold on Rumble's own page; it opens with its Join panel already up.
                RumbleWebSheet(title: "Join \(channel.name)", url: channel.url,
                               script: "document.querySelector('[data-js=locals-subscription-button]')?.click()")
            }
            .sheet(isPresented: $showTip) {
                if let id = tipID { TipQRSheet(channel: channel, tipID: id).presentationDetents([.medium, .large]) }
            }
        }
    }
}

/// The creator's Rumble Wallet QR code, fetched from the same panel rumble.com shows for "Tip".
struct TipQRSheet: View {
    let channel: ChannelRef
    let tipID: String
    @Environment(\.dismiss) private var dismiss
    @State private var qr: UIImage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    ChannelAvatar(name: channel.name, url: channel.avatar, size: 36, path: channel.path)
                    Text(channel.name).font(.headline)
                }
                if let qr {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                        .frame(maxWidth: 260).padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
                    Text("Scan with Rumble Wallet to tip \(channel.name).").font(.footnote).foregroundStyle(.secondary)
                    ShareLink(item: Image(uiImage: qr), preview: SharePreview("Tip \(channel.name)", image: Image(uiImage: qr))) {
                        Label("Share QR code", systemImage: "square.and.arrow.up")
                    }
                } else if failed {
                    Text("Couldn't load the tip code.").foregroundStyle(.secondary)
                    Button("Open on rumble.com") { UIApplication.shared.open(channel.url) }
                } else {
                    ProgressView().frame(height: 200)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Tip with Rumble Wallet").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        guard let url = CreatorExtras.qrModalURL(tipID: tipID) else { failed = true; return }
        var r = URLRequest(url: url)
        r.setValue("true", forHTTPHeaderField: "HX-Request")
        r.setValue(channel.url.absoluteString, forHTTPHeaderField: "Referer")
        guard let res = try? await RumbleHTTP.session.data(for: r), (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let data = CreatorExtras.qrImageData(String(decoding: res.0, as: UTF8.self)), let img = UIImage(data: data) else {
            failed = true; return
        }
        qr = img
    }
}
