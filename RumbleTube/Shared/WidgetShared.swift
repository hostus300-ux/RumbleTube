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
/// Lock Screen / Dynamic Island view of the live stream you're watching.
@available(iOS 16.1, *)
struct LiveStreamAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var viewers: Int?
        var behindLive: Int        // seconds behind the live edge
        var isPlaying: Bool
    }
    var title: String
    var channel: String
}
#endif
