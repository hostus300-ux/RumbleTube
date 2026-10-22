import Foundation

// MARK: - Tabs

enum AppTab: String, Codable, CaseIterable, Identifiable {
    case home, shorts, discover
    case myFeed = "my-feed"
    case account
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .shorts: return "Shorts"
        case .discover: return "Discover"
        case .myFeed: return "My Feed"
        case .account: return "Me"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .shorts: return "play.circle"
        case .discover: return "safari"
        case .myFeed: return "play.rectangle.on.rectangle"
        case .account: return "person.crop.circle"
        }
    }
    /// Account holds Settings, so it can't be turned off.
    var required: Bool { self == .account }
}

struct TabSetting: Codable, Hashable, Identifiable {
    var tab: AppTab
    var enabled: Bool
    var id: AppTab { tab }
}

// MARK: - Appearance

enum ThemeMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case green, blue, red, orange, purple, pink, teal
    var id: String { rawValue }
    var title: String { self == .green ? "Rumble green" : rawValue.capitalized }
    var hex: UInt32 {
        switch self {
        case .green: return 0x85C742
        case .blue: return 0x3B82F6
        case .red: return 0xEF4444
        case .orange: return 0xF59E0B
        case .purple: return 0x8B5CF6
        case .pink: return 0xEC4899
        case .teal: return 0x14B8A6
        }
    }
}

// MARK: - Player gestures

enum PlayerGesture: String, Codable, CaseIterable, Identifiable {
    case doubleTapLeft, doubleTapRight, doubleTapCenter, longPress, swipeUp, swipeDown, pinch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .doubleTapLeft: return "Double-tap left side"
        case .doubleTapRight: return "Double-tap right side"
        case .doubleTapCenter: return "Double-tap middle"
        case .longPress: return "Press and hold"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        case .pinch: return "Pinch"
        }
    }
    var defaultAction: GestureAction {
        switch self {
        case .doubleTapLeft: return .seekBack
        case .doubleTapRight: return .seekForward
        case .doubleTapCenter: return .playPause
        case .longPress: return .speedBoost
        case .swipeUp: return .fullscreen
        case .swipeDown: return .minimize
        case .pinch: return .toggleZoom
        }
    }
    /// "Speed boost" only makes sense while holding.
    var allowedActions: [GestureAction] {
        GestureAction.allCases.filter { $0 != .speedBoost || self == .longPress }
    }
}

enum GestureAction: String, Codable, CaseIterable, Identifiable {
    case none, seekBack, seekForward, playPause, speedBoost, fullscreen, minimize, close, skipSegment, toggleZoom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Nothing"
        case .seekBack: return "Rewind"
        case .seekForward: return "Fast-forward"
        case .playPause: return "Play / pause"
        case .speedBoost: return "Speed boost while held"
        case .fullscreen: return "Toggle fullscreen"
        case .minimize: return "Minimize player"
        case .close: return "Close player"
        case .skipSegment: return "Skip RumbleSkip segment"
        case .toggleZoom: return "Zoom to fill / fit"
        }
    }
}

// MARK: - All preferences

struct AppPreferences: Codable, Equatable {
    var tabs: [TabSetting] = AppTab.allCases.map { TabSetting(tab: $0, enabled: true) }
    var theme: ThemeMode = .system
    var accent: AccentChoice = .green
    var gestures: [String: GestureAction] = [:]
    var seekSeconds: Int = 10
    var boostRate: Double = 2.0
    var defaultRate: Double = 1.0
    var rotateToFullscreen = true
    /// Start Shorts muted when another app is playing audio, so browsing never interrupts it.
    var shortsMutedWhenOtherAudio = true
    var autoplayShorts = true
    /// iOS 26 Liquid Glass on the app's own controls (header, chips, mini player).
    var liquidGlass = true
    /// "+" (upload / go live) button in the page header. Off unless turned on in Settings.
    var showCreateButton = false
    /// Highest quality to save when downloading.
    var downloadHeight = 720
    /// Notify when channels you follow go live.
    var liveAlerts = false
    /// Play with the lowest-bitrate stream and show artwork instead of video.
    var audioOnly = false
    /// When off (default), Audio only applies to the current video only.
    var audioOnlySticky = false
    /// Play the next recommended video when one ends (with a countdown to cancel).
    var autoplay = true
    /// Tab bar shrinks while scrolling (iOS 26).
    var minimizeTabBar = true
    /// Landing view for each tab.
    var homeFilter = "All"
    var discoverPage = "Videos"
    var discoverSort = "Trending"
    var myFeedPill = "all"

    static let seekChoices = [5, 10, 15, 30]
    static let rateChoices: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    func action(for g: PlayerGesture) -> GestureAction { gestures[g.rawValue] ?? g.defaultAction }

    /// Enabled tabs in the user's order. Library is always present; new app tabs get appended.
    var visibleTabs: [AppTab] {
        normalizedTabs.filter { $0.enabled || $0.tab.required }.map(\.tab)
    }

    var normalizedTabs: [TabSetting] {
        var seen = Set<AppTab>()
        var out = tabs.filter { seen.insert($0.tab).inserted }
        // Tabs added in an update go in their default spot (e.g. Create after Shorts), not at the end.
        for (i, t) in AppTab.allCases.enumerated() where !seen.contains(t) {
            let before = AppTab.allCases.prefix(i)
            let at = (out.lastIndex { before.contains($0.tab) }).map { $0 + 1 } ?? 0
            out.insert(TabSetting(tab: t, enabled: true), at: at)
        }
        return out.map { $0.tab.required ? TabSetting(tab: $0.tab, enabled: true) : $0 }
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case tabs, theme, accent, gestures, seekSeconds, boostRate, defaultRate, rotateToFullscreen
        case shortsMutedWhenOtherAudio, autoplayShorts, liquidGlass, downloadHeight, liveAlerts
        case audioOnly, audioOnlySticky, autoplay, minimizeTabBar, homeFilter, discoverPage, discoverSort, myFeedPill
        case showCreateButton = "createButtonOn"   // renamed so the old default (on) is not carried over
    }

    // Tolerant decoding: settings added in later versions fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppPreferences()
        if let raw = try? c.decodeIfPresent([[String: AnyCodableBool]].self, forKey: .tabs) {
            let parsed = raw.compactMap { r -> TabSetting? in
                guard let t = r["tab"]?.string.flatMap(AppTab.init(rawValue:)) else { return nil }
                return TabSetting(tab: t, enabled: r["enabled"]?.bool ?? true)
            }
            tabs = parsed.isEmpty ? d.tabs : parsed
        } else { tabs = d.tabs }
        theme = (try? c.decodeIfPresent(ThemeMode.self, forKey: .theme)) ?? d.theme
        accent = (try? c.decodeIfPresent(AccentChoice.self, forKey: .accent)) ?? d.accent
        gestures = (try? c.decodeIfPresent([String: GestureAction].self, forKey: .gestures)) ?? d.gestures
        seekSeconds = (try? c.decodeIfPresent(Int.self, forKey: .seekSeconds)) ?? d.seekSeconds
        boostRate = (try? c.decodeIfPresent(Double.self, forKey: .boostRate)) ?? d.boostRate
        defaultRate = (try? c.decodeIfPresent(Double.self, forKey: .defaultRate)) ?? d.defaultRate
        rotateToFullscreen = (try? c.decodeIfPresent(Bool.self, forKey: .rotateToFullscreen)) ?? d.rotateToFullscreen
        shortsMutedWhenOtherAudio = (try? c.decodeIfPresent(Bool.self, forKey: .shortsMutedWhenOtherAudio)) ?? d.shortsMutedWhenOtherAudio
        autoplayShorts = (try? c.decodeIfPresent(Bool.self, forKey: .autoplayShorts)) ?? d.autoplayShorts
        liquidGlass = (try? c.decodeIfPresent(Bool.self, forKey: .liquidGlass)) ?? d.liquidGlass
        showCreateButton = (try? c.decodeIfPresent(Bool.self, forKey: .showCreateButton)) ?? d.showCreateButton
        downloadHeight = (try? c.decodeIfPresent(Int.self, forKey: .downloadHeight)) ?? d.downloadHeight
        liveAlerts = (try? c.decodeIfPresent(Bool.self, forKey: .liveAlerts)) ?? d.liveAlerts
        audioOnly = (try? c.decodeIfPresent(Bool.self, forKey: .audioOnly)) ?? d.audioOnly
        audioOnlySticky = (try? c.decodeIfPresent(Bool.self, forKey: .audioOnlySticky)) ?? d.audioOnlySticky
        autoplay = (try? c.decodeIfPresent(Bool.self, forKey: .autoplay)) ?? d.autoplay
        minimizeTabBar = (try? c.decodeIfPresent(Bool.self, forKey: .minimizeTabBar)) ?? d.minimizeTabBar
        homeFilter = (try? c.decodeIfPresent(String.self, forKey: .homeFilter)) ?? d.homeFilter
        discoverPage = (try? c.decodeIfPresent(String.self, forKey: .discoverPage)) ?? d.discoverPage
        discoverSort = (try? c.decodeIfPresent(String.self, forKey: .discoverSort)) ?? d.discoverSort
        myFeedPill = (try? c.decodeIfPresent(String.self, forKey: .myFeedPill)) ?? d.myFeedPill
    }
}

/// Decodes either a string or a bool (for reading old tab settings leniently).
struct AnyCodableBool: Codable {
    var string: String?
    var bool: Bool?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { bool = b } else { string = try? c.decode(String.self) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let bool { try c.encode(bool) } else { try c.encode(string) }
    }
}
