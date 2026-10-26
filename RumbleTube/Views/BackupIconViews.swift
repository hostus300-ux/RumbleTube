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

// MARK: - App icon

/// Switch between RumbleTube's built-in icons (real app icons; iOS confirms the change).
struct CustomIconView: View {
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 14)], spacing: 16) {
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
                .padding(.vertical, 8)
                if let iconError { Text(iconError).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("Changes the app's icon on your Home Screen. iOS shows a short confirmation when it switches.")
            }
        }
        .navigationTitle("App icon")
    }

    private func setIcon(_ name: String?) {
        guard UIApplication.shared.supportsAlternateIcons else { iconError = "This phone doesn't allow changing the icon."; return }
        UIApplication.shared.setAlternateIconName(name) { err in
            DispatchQueue.main.async {
                if let err { iconError = err.localizedDescription } else { iconError = nil; currentIcon = name }
            }
        }
    }
}
