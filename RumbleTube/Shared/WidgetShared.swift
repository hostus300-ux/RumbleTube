import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Data the app hands to its widgets through the shared App Group container.
enum WidgetShared {
    static let appGroup = "group.com.hostus300.rumbletube"
    static let fileName = "widget-snapshot.json"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(fileName)
    }

    static func load() -> WidgetSnapshot? {
        guard let url, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }

    static func save(_ s: WidgetSnapshot) {
        guard let url, let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: .atomic)
    }

    /// rumbletube://open?url=https://rumble.com/… (handled by the app's Router)
    static func deepLink(_ rumbleURL: String) -> URL? {
        var c = URLComponents(string: "rumbletube://open")!
        c.queryItems = [URLQueryItem(name: "url", value: rumbleURL)]
        return c.url
    }
}

struct WidgetSnapshot: Codable {
    struct LiveChannel: Codable, Hashable {
        var name: String
        var path: String
        var viewers: Int?
        var avatar: Data?
    }
    struct Video: Codable, Hashable {
        var id: String
        var title: String
        var channel: String?
        var url: String
        var progress: Double
        var thumb: Data?
    }
    var liveNow: [LiveChannel] = []
    var continueWatching: [Video] = []
    var signedIn = false
    var updatedAt = Date()
}

#if canImport(ActivityKit)
/// Lock Screen / Dynamic Island card while a live stream or an audio-only video plays.
@available(iOS 16.1, *)
struct LiveStreamAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var viewers: Int?
        var behindLive: Int        // seconds behind the live edge
        var isPlaying: Bool
        var isLive: Bool = true
        var position: Double = 0   // seconds (videos)
        var duration: Double = 0
        var updatedAt: Date = Date()
    }
    var title: String
    var channel: String
    var audioOnly: Bool = false
}
#endif

// MARK: - Buttons on the Live Activity (run inside the app)

/// What a Live Activity button asks the player to do. The app installs `handler` at launch;
/// in the widget process it's nil and the buttons do nothing there (iOS runs them in the app).
enum PlayerCommandBridge {
    enum Command { case skip(Double), togglePlay, goLive }
    @MainActor static var handler: ((Command) -> Void)?
}

#if canImport(AppIntents)
import AppIntents

@available(iOS 17.0, *)
struct SkipIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Skip"
    @Parameter(title: "Seconds") var seconds: Double
    init() { seconds = 10 }
    init(seconds: Double) { self.seconds = seconds }
    @MainActor func perform() async throws -> some IntentResult {
        PlayerCommandBridge.handler?(.skip(seconds))
        return .result()
    }
}

@available(iOS 17.0, *)
struct TogglePlayIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or pause"
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        PlayerCommandBridge.handler?(.togglePlay)
        return .result()
    }
}

@available(iOS 17.0, *)
struct GoLiveIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Jump to live"
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        PlayerCommandBridge.handler?(.goLive)
        return .result()
    }
}
#endif
