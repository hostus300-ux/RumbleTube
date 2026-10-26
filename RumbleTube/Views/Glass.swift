import SwiftUI
import UIKit

// MARK: - Liquid Glass (iOS 26) with graceful fallback
//
// Built with the iOS 26 SDK, the system tab bar, navigation bars and sheets get Liquid Glass automatically.
// These helpers put the same material on RumbleTube's own controls, and fall back to blur on older iOS
// (or when "Liquid Glass" is turned off in Settings).

enum GlassUI {
    static var available: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
    @MainActor static var enabled: Bool { available && LibraryStore.shared.data.prefs.liquidGlass }

    /// iOS 26.1+: the mini player lives in the tab bar (like Apple Music) instead of floating over content.
    static var accessoryAvailable: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.1, *) { return true }
        #endif
        return false
    }
    @MainActor static var usesAccessory: Bool { accessoryAvailable && LibraryStore.shared.data.prefs.liquidGlass }
}

private struct GlassShape<S: Shape>: ViewModifier {
    let shape: S
    var interactive = true
    var tint: Color? = nil
    @EnvironmentObject var library: LibraryStore

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), library.data.prefs.liquidGlass {
            content.glassEffect(glass, in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var glass: SwiftUI.Glass {
        var g = SwiftUI.Glass.regular
        if let tint { g = g.tint(tint) }
        return interactive ? g.interactive() : g
    }
    #endif

    private func fallback(_ content: Content) -> some View {
        content.background {
            if let tint { shape.fill(tint) } else { shape.fill(.ultraThinMaterial) }
        }
    }
}

extension View {
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(GlassShape(shape: Capsule(), interactive: interactive, tint: tint))
    }
    func glassCircle(tint: Color? = nil) -> some View {
        modifier(GlassShape(shape: Circle(), tint: tint))
    }
    func glassCard(_ radius: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(GlassShape(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), interactive: interactive))
    }

    /// Groups nearby glass shapes so they blend like Apple's own toolbars (no-op before iOS 26).
    @ViewBuilder func glassGroup(spacing: CGFloat = 8) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
        #else
        self
        #endif
    }

    /// iOS 26.1+: dock the mini player in the tab bar. It sits above the tabs, and moves inline beside the
    /// collapsed tab button while scrolling (Apple Music behaviour).
    @ViewBuilder func miniPlayerAccessory(enabled: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.1, *) {
            self.tabViewBottomAccessory(isEnabled: enabled) { MiniPlayerAccessory() }
        } else { self }
        #else
        self
        #endif
    }

    /// iOS 26: tab bar shrinks while scrolling down, like Apple Music / App Store.
    @ViewBuilder func minimizingTabBar(_ on: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self.tabBarMinimizeBehavior(on ? .onScrollDown : .never) } else { self }
        #else
        self
        #endif
    }
}

// MARK: - Page header: title with bell / search on one line (YouTube-style: slides away while you scroll down)

/// Shared between a page's header and its scroll view. Scrolling down slides the header off the top;
/// any scroll up brings it straight back. The header never changes size, so content doesn't jump.
@MainActor
final class HeaderState: ObservableObject {
    @Published private(set) var hidden = false
    @Published var height: CGFloat = 0
    private var lastY: CGFloat = 0
    private var run: CGFloat = 0          // distance scrolled in the current direction

    func scrolled(to y: CGFloat) {
        let dy = y - lastY
        lastY = y
        if y <= 8 { run = 0; set(false); return }                  // at the top (or pulling to refresh)
        if dy == 0 { return }
        if (dy > 0) != (run > 0) { run = 0 }                        // direction changed
        run += dy
        if run > 28, y > height { set(true) }
        else if run < -16 { set(false) }
    }

    private func set(_ h: Bool) {
        if hidden != h { hidden = h }
        // Scrolling back up also brings the shrunken tab bar back (iOS otherwise waits until you reach the top).
        TabBarState.shared.setExpandedByScroll(!h)
    }
}

/// Lets a scroll up re-expand the iOS 26 shrunken tab bar.
@MainActor
final class TabBarState: ObservableObject {
    static let shared = TabBarState()
    @Published private(set) var keepExpanded = true
    func setExpandedByScroll(_ up: Bool) { if keepExpanded != up { keepExpanded = up } }
}

private struct HeaderStateKey: EnvironmentKey { static let defaultValue: HeaderState? = nil }
extension EnvironmentValues {
    var headerState: HeaderState? {
        get { self[HeaderStateKey.self] }
        set { self[HeaderStateKey.self] = newValue }
    }
}

/// Put on a page's main ScrollView so the header can slide away while scrolling (iOS 18+; no-op before).
private struct ReportsScroll: ViewModifier {
    @Environment(\.headerState) private var header
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let header {
            content.onScrollGeometryChange(for: CGFloat.self) { ($0.contentOffset.y + $0.contentInsets.top).rounded() } action: { _, y in
                header.scrolled(to: y)
            }
        } else {
            content
        }
    }
}

extension View {
    func reportsScrollToHeader() -> some View { modifier(ReportsScroll()) }
}

private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct AppHeader: ViewModifier {
    let title: String
    var settings = false
    /// Extra controls shown under the title inside the header (e.g. Discover's Videos / Live).
    var accessory: AnyView? = nil
    /// Accessory runs edge to edge (scrolling chip rows).
    var fullWidthAccessory = false
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var library: LibraryStore
    @StateObject private var state = HeaderState()

    func body(content: Content) -> some View {
        content
            .environment(\.headerState, state)
            .navigationTitle(title)                  // used for the back button on pushed screens
            .toolbar(.hidden, for: .navigationBar)
            // Reserve the header's height once; it doesn't change while scrolling, so nothing jumps.
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: state.height) }
            .overlay(alignment: .top) {
                bar
                    .background(GeometryReader { Color.clear.preference(key: HeaderHeightKey.self, value: $0.size.height) })
                    .background(Color(.systemBackground))
                    .offset(y: state.hidden ? -(state.height + 2) : 0)
                    .opacity(state.hidden ? 0 : 1)
                    .animation(.easeOut(duration: 0.22), value: state.hidden)
                    .onPreferenceChange(HeaderHeightKey.self) { h in if abs(h - state.height) > 0.5 { state.height = h } }
            }
            // Solid strip behind the status bar, so scrolled content never shows through it
            // and the header slides away underneath it (like YouTube).
            .overlay(alignment: .top) {
                let top = Self.statusBarHeight
                Color(.systemBackground)
                    .frame(height: top)
                    .offset(y: -top)
                    .allowsHitTesting(false)
            }
    }

    private static var statusBarHeight: CGFloat {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return window?.safeAreaInsets.top ?? 0
    }

    private var bar: some View {
        VStack(spacing: 6) {
            titleRow
            if let accessory { accessory.padding(.horizontal, fullWidthAccessory ? 0 : 16) }
        }
        .padding(.bottom, 6)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.title2.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if library.data.prefs.showCreateButton { icon(.create, "tab-create", "Create", asset: true) }
                icon(.inbox, account.hasUnread ? "bell.badge" : "bell", "Notifications", badge: account.hasUnread)
                icon(.search, "magnifyingglass", "Search")
                if settings { icon(.settings, "gearshape", "Settings") }
            }
            .glassGroup()
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    private func icon(_ route: AppRoute, _ name: String, _ label: String, badge: Bool = false, asset: Bool = false) -> some View {
        NavigationLink(value: route) {
            Group {
                if asset {
                    Image(name).renderingMode(.template).resizable().scaledToFit().frame(width: 18, height: 18)
                } else {
                    Image(systemName: name)
                        .symbolRenderingMode(badge ? .multicolor : .monochrome)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
            .glassCircle()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(label)
    }
}

extension View {
    func appHeader(_ title: String, settings: Bool = false) -> some View { modifier(AppHeader(title: title, settings: settings)) }
    func appHeader<A: View>(_ title: String, @ViewBuilder accessory: () -> A) -> some View {
        modifier(AppHeader(title: title, accessory: AnyView(accessory())))
    }
    /// Header with a chip row under the title; the chips slide away and come back with the header (like YouTube).
    func appHeader<A: View>(_ title: String, @ViewBuilder chips: () -> A) -> some View {
        modifier(AppHeader(title: title, accessory: AnyView(chips()), fullWidthAccessory: true))
    }
}
