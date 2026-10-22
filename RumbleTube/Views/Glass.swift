import SwiftUI

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

// MARK: - Page header: big title with search / bell / settings on the same line

/// Shared between a page's header and its scroll view: scrolling down compacts the header, scrolling up restores it.
final class HeaderState: ObservableObject {
    @Published var compact = false
    private var lastY: CGFloat = 0

    func scrolled(to y: CGFloat) {
        let dy = y - lastY
        lastY = y
        if y < 30 { if compact { compact = false }; return }        // near the top: full header
        if dy > 6, !compact { compact = true }                        // scrolling down
        else if dy < -10, compact { compact = false }                 // scrolling up a little brings it back
    }
}

private struct HeaderStateKey: EnvironmentKey { static let defaultValue: HeaderState? = nil }
extension EnvironmentValues {
    var headerState: HeaderState? {
        get { self[HeaderStateKey.self] }
        set { self[HeaderStateKey.self] = newValue }
    }
}

/// Put on a page's main ScrollView so the header can shrink while scrolling (iOS 18+; no-op before).
private struct ReportsScroll: ViewModifier {
    @Environment(\.headerState) private var header
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let header {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                withAnimation(.easeInOut(duration: 0.2)) { header.scrolled(to: y) }
            }
        } else {
            content
        }
    }
}

extension View {
    func reportsScrollToHeader() -> some View { modifier(ReportsScroll()) }
}

struct AppHeader: ViewModifier {
    let title: String
    var settings = false
    /// Extra controls shown under the title inside the same glass bar (e.g. Discover's Videos / Live).
    var accessory: AnyView? = nil
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var library: LibraryStore
    @StateObject private var state = HeaderState()

    func body(content: Content) -> some View {
        let base = content
            .environment(\.headerState, state)
            .navigationTitle(title)                  // used for the back button on pushed screens
            .toolbar(.hidden, for: .navigationBar)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), library.data.prefs.liquidGlass {
            // safeAreaBar adds the iOS 26 scroll-edge blur under the header, like Apple's apps.
            base.safeAreaBar(edge: .top, spacing: 0) { bar }
        } else {
            base.safeAreaInset(edge: .top, spacing: 0) { bar.background(Rectangle().fill(.bar).ignoresSafeArea(edges: .top)) }
        }
        #else
        base.safeAreaInset(edge: .top, spacing: 0) { bar.background(Rectangle().fill(.bar).ignoresSafeArea(edges: .top)) }
        #endif
    }

    private var compact: Bool { state.compact }

    private var bar: some View {
        VStack(spacing: compact ? 4 : 6) {
            titleRow
            if let accessory { accessory.padding(.horizontal, 16) }
        }
        .padding(.bottom, accessory == nil ? 0 : 6)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(compact ? .headline.weight(.bold) : .title2.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            HStack(spacing: compact ? 4 : 6) {
                if library.data.prefs.showCreateButton { icon(.create, "video.badge.plus", "Create") }
                icon(.inbox, account.hasUnread ? "bell.badge" : "bell", "Notifications", badge: account.hasUnread)
                icon(.search, "magnifyingglass", "Search")
                if settings { icon(.settings, "gearshape", "Settings") }
            }
            .glassGroup()
        }
        .padding(.horizontal, 16)
        .padding(.top, compact ? 0 : 2).padding(.bottom, compact ? 4 : 6)
        .animation(.easeInOut(duration: 0.2), value: compact)
    }

    private func icon(_ route: AppRoute, _ name: String, _ label: String, badge: Bool = false) -> some View {
        NavigationLink(value: route) {
            Image(systemName: name)
                .symbolRenderingMode(badge ? .multicolor : .monochrome)
                .font(.system(size: compact ? 13 : 15, weight: .semibold))
                .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
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
}
