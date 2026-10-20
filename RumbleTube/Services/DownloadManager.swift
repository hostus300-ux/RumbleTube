import Foundation
import SwiftUI
import UIKit

/// Saves videos as MP4 files for offline viewing. Uses a background URLSession so downloads keep going
/// when you leave the app.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    static let sessionID = "com.hostus300.rumbletube.downloads"

    @Published private(set) var records: [DownloadRecord] = []
    /// Active downloads: video id → 0…1
    @Published private(set) var progress: [String: Double] = [:]
    @Published var lastError: String?

    var backgroundCompletion: (() -> Void)?
    private var pending: [String: (VideoDetail, VideoItem, StreamOption)] = [:]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.httpAdditionalHeaders = ["User-Agent": RumbleHTTP.userAgent, "Referer": "https://rumble.com/"]
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    static var folder: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var index: URL { folder.appendingPathComponent("index.json") }

    override init() {
        super.init()
        records = (try? Data(contentsOf: Self.index)).flatMap { try? JSONDecoder().decode([DownloadRecord].self, from: $0) } ?? []
        records.removeAll { !FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent($0.fileName).path) }
        _ = session   // reconnect to downloads that finished while the app was closed
    }

    // MARK: queries

    func record(_ id: String) -> DownloadRecord? { records.first { $0.id == id } }
    func isDownloaded(_ id: String) -> Bool { record(id) != nil }
    func fileURL(_ r: DownloadRecord) -> URL { Self.folder.appendingPathComponent(r.fileName) }
    var totalBytes: Int64 { records.reduce(0) { $0 + $1.bytes } }

    // MARK: actions

    func download(_ item: VideoItem) {
        guard progress[item.id] == nil, !isDownloaded(item.id) else { return }
        progress[item.id] = 0
        Task {
            do {
                let d = try await RumbleService.shared.detail(for: item)
                guard d.liveStatus != .isLive,
                      let s = DownloadPlan.stream(from: d.streams, maxHeight: LibraryStore.shared.data.prefs.downloadHeight),
                      let url = URL(string: s.url) else {
                    progress[item.id] = nil
                    lastError = "This video can't be downloaded (live streams and some videos only offer streaming)."
                    return
                }
                var it = item
                if it.thumbnail == nil { it.thumbnail = d.thumbnail }
                pending[item.id] = (d, it, s)
                let task = session.downloadTask(with: url)
                task.taskDescription = item.id
                task.resume()
            } catch {
                progress[item.id] = nil
                lastError = error.localizedDescription
                DiagLog.shared.log("download", "\(item.id): \(error.localizedDescription)")
            }
        }
    }

    func cancel(_ id: String) {
        session.getAllTasks { tasks in tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
        progress[id] = nil
        pending[id] = nil
    }

    func delete(_ id: String) {
        guard let r = record(id) else { return }
        try? FileManager.default.removeItem(at: fileURL(r))
        if let t = r.thumbFile { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(t)) }
        records.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(records) { try? d.write(to: Self.index, options: .atomic) }
    }

    fileprivate func finished(id: String, tmp: URL) {
        let fileName = "\(id).mp4"
        let dest = Self.folder.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: tmp, to: dest) } catch {
            progress[id] = nil; lastError = error.localizedDescription; return
        }
        var excluded = dest; var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? excluded.setResourceValues(rv)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        let p = pending.removeValue(forKey: id)
        let detail = p?.0 ?? VideoDetail(id: id, url: "https://rumble.com/\(id)", embedId: "", title: id, liveStatus: .notLive, streams: [])
        let item = p?.1 ?? detail.asItem
        var rec = DownloadRecord(detail: detail, item: item, fileName: fileName, thumbFile: nil, bytes: bytes,
                                 quality: p?.2.label ?? "MP4", savedAt: Date())
        records.removeAll { $0.id == id }
        records.insert(rec, at: 0)
        progress[id] = nil
        save()
        // keep the thumbnail for offline lists
        if let t = item.thumbnail, let u = URL(string: t) {
            Task {
                guard let res = try? await URLSession.shared.data(from: u) else { return }
                let name = "\(id).jpg"
                try? res.0.write(to: Self.folder.appendingPathComponent(name))
                rec.thumbFile = name
                rec.item.thumbnail = Self.folder.appendingPathComponent(name).absoluteString
                if let i = records.firstIndex(where: { $0.id == id }) { records[i] = rec; save() }
            }
        }
    }

    fileprivate func failed(id: String, error: Error) {
        progress[id] = nil
        pending[id] = nil
        if (error as? URLError)?.code != .cancelled {
            lastError = error.localizedDescription
            DiagLog.shared.log("download", "\(id): \(error.localizedDescription)")
        }
    }

    fileprivate func setProgress(_ id: String, _ p: Double) { progress[id] = p }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // the temp file disappears when this method returns, so move it out synchronously first
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).mp4")
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard code == 200, (try? FileManager.default.moveItem(at: location, to: keep)) != nil else {
            Task { @MainActor in self.failed(id: id, error: URLError(.badServerResponse)) }
            return
        }
        Task { @MainActor in self.finished(id: id, tmp: keep) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.setProgress(id, p) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        Task { @MainActor in self.failed(id: id, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.backgroundCompletion?(); self.backgroundCompletion = nil }
    }
}

// MARK: - Views

/// Download button for the player's action row.
struct DownloadPill: View {
    let item: VideoItem
    @ObservedObject private var dm = DownloadManager.shared

    var body: some View {
        Button {
            if dm.isDownloaded(item.id) { return }
            if dm.progress[item.id] != nil { dm.cancel(item.id) } else { dm.download(item) }
        } label: {
            Group {
                if dm.isDownloaded(item.id) {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                } else if let p = dm.progress[item.id] {
                    Label("\(Int(p * 100))%", systemImage: "xmark.circle")
                } else {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(dm.isDownloaded(item.id) ? Color.rumbleGreen.opacity(0.25) : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(dm.isDownloaded(item.id) ? Color.rumbleGreen : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct DownloadsScreen: View {
    @ObservedObject private var dm = DownloadManager.shared
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        List {
            if !dm.progress.isEmpty {
                Section("Downloading") {
                    ForEach(dm.progress.sorted { $0.key < $1.key }, id: \.key) { id, p in
                        HStack {
                            ProgressView(value: p)
                            Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                            Button { dm.cancel(id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            Section {
                ForEach(dm.records) { r in
                    Button { player.play(r.item) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            VideoRow(item: r.item)
                            Text("\(r.quality) · \(DownloadPlan.size(r.bytes))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { idx in idx.map { dm.records[$0].id }.forEach(dm.delete) }
            } header: {
                if !dm.records.isEmpty { Text("\(dm.records.count) videos · \(DownloadPlan.size(dm.totalBytes))") }
            }
            Section {
                Picker("Download quality", selection: Binding(get: { library.data.prefs.downloadHeight },
                                                              set: { library.data.prefs.downloadHeight = $0 })) {
                    ForEach(DownloadPlan.qualityChoices, id: \.self) { Text("Up to \($0)p").tag($0) }
                }
            } footer: { Text("Live streams can't be downloaded. Downloads play without a connection.") }
        }
        .overlay { if dm.records.isEmpty && dm.progress.isEmpty { Text("Tap Download under any video.").foregroundStyle(.secondary) } }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Download failed", isPresented: Binding(get: { dm.lastError != nil }, set: { if !$0 { dm.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(dm.lastError ?? "") }
        .miniPlayerSpace()
    }
}
