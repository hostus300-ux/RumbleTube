import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings backup

/// Export / import of everything RumbleTube-specific, so a reinstall or sideload refresh doesn't mean redoing it all.
struct BackupSection: View {
    @EnvironmentObject var library: LibraryStore
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var pending: SettingsBackup?
    @State private var message: String?

    var body: some View {
        Section {
            if let url = exportURL {
                ShareLink(item: url) { Label("Save settings file…", systemImage: "square.and.arrow.up") }
            } else {
                Button { export() } label: { Label("Export settings", systemImage: "square.and.arrow.up") }
            }
            Button { importing = true } label: { Label("Import settings…", systemImage: "square.and.arrow.down") }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Backup") } footer: {
            Text("Saves your RumbleTube settings, RumbleSkip setup and your own skip segments, muted channels and tags, phone follows and Watch Later to one file. Watch history and your Rumble sign-in aren't included.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data, .item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { pending = try SettingsBackup.decode(Data(contentsOf: url)) }
            catch { message = "That file isn't a RumbleTube settings backup." }
        }
        .confirmationDialog("Import settings?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Import") {
                if let b = pending { b.apply(to: &library.data); PlayerModel.shared.settingsChanged(); message = "Imported \(b.summary)." }
                pending = nil
            }
        } message: {
            if let b = pending {
                Text("From \(b.appVersion.map { "version \($0), " } ?? "")\(b.exportedAt.formatted(date: .abbreviated, time: .shortened)): \(b.summary). Settings are replaced; lists are merged with what's already here.")
            }
        }
    }

    private func export() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let day = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RumbleTube-settings-\(day).json")
        do {
            try SettingsBackup(from: library.data, appVersion: version).encoded().write(to: url, options: .atomic)
            exportURL = url
            message = "Ready. Tap Save settings file and choose Save to Files."
        } catch {
            message = "Couldn't create the file: \(error.localizedDescription)"
        }
    }
}

// MARK: - Custom Home Screen icon

/// iOS won't let a sideloaded app swap in an arbitrary picture as its icon, so this makes a
/// Home Screen icon (Web Clip) from your picture that opens RumbleTube.
struct CustomIconView: View {
    @State private var pick: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var name = "Rumble"
    @State private var profileURL: URL?
    @State private var error: String?
    private let side: CGFloat = 220

    @State private var currentIcon = UIApplication.shared.alternateIconName
    @State private var iconError: String?
    private struct IconOption { let name: String?; let label: String; let preview: String }
    private let builtIn: [IconOption] = [
        .init(name: nil, label: "Classic", preview: "IconPreview-Default"),
        .init(name: "AppIcon-Light", label: "Light", preview: "IconPreview-Light"),
        .init(name: "AppIcon-Red", label: "Live red", preview: "IconPreview-Red"),
        .init(name: "AppIcon-Waves", label: "Waves", preview: "IconPreview-Waves"),
        .init(name: "AppIcon-Mono", label: "Mono", preview: "IconPreview-Mono"),
    ]

    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(builtIn, id: \.label) { opt in
                            Button { setIcon(opt.name) } label: {
                                VStack(spacing: 6) {
                                    Image(opt.preview).resizable().frame(width: 62, height: 62)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(currentIcon == opt.name ? Color.rumbleGreen : .clear, lineWidth: 3).padding(-3))
                                    Text(opt.label).font(.caption2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 2)
                }
                if let iconError { Text(iconError).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("App icon")
            } footer: {
                Text("Changes the real app icon. iOS shows a short confirmation when it switches.")
            }

            Section {
                VStack(spacing: 14) {
                    crop
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous).stroke(.secondary.opacity(0.3)))
                        .gesture(DragGesture()
                            .onChanged { v in offset = CGSize(width: dragStart.width + v.translation.width, height: dragStart.height + v.translation.height) }
                            .onEnded { _ in dragStart = offset })
                    PhotosPicker(selection: $pick, matching: .images) {
                        Label(image == nil ? "Choose a picture" : "Choose another", systemImage: "photo")
                    }
                    if image != nil {
                        HStack {
                            Image(systemName: "minus.magnifyingglass")
                            Slider(value: $zoom, in: 1...4)
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } header: {
                Text("Your own picture")
            } footer: {
                Text("iOS doesn't let an app use a photo as its real icon, so your picture becomes a Home Screen shortcut that opens RumbleTube. Drag to position, use the slider to zoom.")
            }

            Section("Name under the icon") {
                TextField("Rumble", text: $name)
                    .onChange(of: name) { n in if n.count > 30 { name = String(n.prefix(30)) } }
            }

            Section {
                if let url = profileURL {
                    ShareLink(item: url) { Label("Save icon file…", systemImage: "square.and.arrow.up") }
                } else {
                    Button { make() } label: { Label("Create Home Screen icon", systemImage: "apps.iphone.badge.plus") }
                        .disabled(image == nil)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("""
                1. Tap Save icon file → Save to Files.
                2. Open the Files app and tap the file. iOS says "Profile Downloaded".
                3. Settings → General → VPN & Device Management → the Rumble icon profile → Install.
                The new icon opens RumbleTube. You can drag the original icon to the App Library to hide it. To remove the custom icon, long-press it and choose Remove, or delete the profile in Settings.
                """)
            }
        }
        .navigationTitle("App icon")
        .onChange(of: pick) { p in
            Task {
                guard let d = try? await p?.loadTransferable(type: Data.self), let img = UIImage(data: d) else { return }
                image = img; zoom = 1; offset = .zero; dragStart = .zero; profileURL = nil
            }
        }
        .onChange(of: zoom) { _ in profileURL = nil }
        .onChange(of: offset) { _ in profileURL = nil }
        .onChange(of: name) { _ in profileURL = nil }
    }

    @ViewBuilder private var crop: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: side, height: side)
                .scaleEffect(zoom)
                .offset(offset)
                .frame(width: side, height: side)
                .clipped()
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
    }

    private func setIcon(_ name: String?) {
        guard UIApplication.shared.supportsAlternateIcons else { iconError = "This phone doesn't allow changing the icon."; return }
        UIApplication.shared.setAlternateIconName(name) { err in
            DispatchQueue.main.async {
                if let err { iconError = err.localizedDescription } else { iconError = nil; currentIcon = name }
            }
        }
    }

    @MainActor private func make() {
        let r = ImageRenderer(content: crop.frame(width: side, height: side))
        r.scale = 512 / side   // 512 × 512, square (iOS rounds the corners)
        guard let png = r.uiImage?.pngData() else { error = "Couldn't draw the icon."; return }
        do {
            let data = try HomeIconProfile.make(name: name, iconPNG: png, bundleID: Bundle.main.bundleIdentifier)
            let safe = name.filter { $0.isLetter || $0.isNumber || $0 == " " }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "Rumble" : safe) icon.mobileconfig")
            try data.write(to: url, options: .atomic)
            profileURL = url; error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
