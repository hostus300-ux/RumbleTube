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

    /// iOS 26: tab bar shrinks while scrolling down, like Apple Music / App Store.
    @ViewBuilder func minimizingTabBar() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self.tabBarMinimizeBehavior(.onScrollDown) } else { self }
        #else
        self
        #endif
    }
}

// MARK: - Page header: big title with search / bell / settings on the same line

struct AppHeader: ViewModifier {
    let title: String
    var settings = false
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var library: LibraryStore

    func body(content: Content) -> some View {
        let base = content
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

    private var bar: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title).font(.largeTitle.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if library.data.prefs.showCreateButton { icon(.create, "plus", "Create") }
                icon(.search, "magnifyingglass", "Search")
                icon(.inbox, account.hasUnread ? "bell.badge" : "bell", "Notifications", badge: account.hasUnread)
                if settings { icon(.settings, "gearshape", "Settings") }
            }
            .glassGroup()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4).padding(.bottom, 8)
    }

    private func icon(_ route: AppRoute, _ name: String, _ label: String, badge: Bool = false) -> some View {
        NavigationLink(value: route) {
            Image(systemName: name)
                .symbolRenderingMode(badge ? .multicolor : .monochrome)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 42, height: 42)
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
}
