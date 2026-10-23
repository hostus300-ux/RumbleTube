import Foundation
import Combine

/// Persists `LibraryData` (follows, history, watch later, positions, RumbleSkip settings) as JSON.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published var data: LibraryData {
        didSet { scheduleSave() }
    }

    private let url: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("library.json")
        if let d = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(LibraryData.self, from: d) {
            data = decoded
        } else {
            data = LibraryData()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            // Encode and write off the main thread: history can be large, and this used to stall scrolling.
            let snapshot = self.data, url = self.url
            await Task.detached(priority: .utility) {
                guard let d = try? JSONEncoder().encode(snapshot) else { return }
                try? d.write(to: url, options: .atomic)
            }.value
        }
    }

    /// Immediate save (app going to the background).
    func saveNow() {
        saveTask?.cancel()
        guard let d = try? JSONEncoder().encode(data) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
