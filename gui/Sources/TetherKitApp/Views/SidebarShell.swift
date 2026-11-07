import SwiftUI
import TetherKitIPC
import TetherKitUIModel

/// Main window frame: sidebar plus content area.
///
/// Styling follows the reference UI set (settings-style windows like
/// Hand Mirror / Dropover): a left column of "colored tile icon + page
/// name" entries, and headered scrolling content on the right. The
/// title bar is transparent with the title hidden (`MainWindowManager`
/// creates the window that way), so the three traffic lights float
/// above the sidebar. The sidebar's top inset (`trafficLightInset`)
/// keeps clear of them.
///
/// Why a hand-rolled sidebar instead of NavigationSplitView:
///
///   NavigationSplitView demands collapsibility and the system's
///   selection styling, and cannot produce the fixed-width,
///   colored-tile look of the reference UIs. This app does not need
///   collapsing (5 pages, all shown). Handling width, selected and
///   hover states by hand costs little and stays in control.
struct SidebarShell: View {
    var model: AppModel

    /// Persisted selection, restored on launch. `@AppStorage` because
    /// the AppKit-owned window has no scene for `@SceneStorage`.
    @AppStorage("tetherkit.sidebar.page") private var storedPage: String = ""

    private var selection: SidebarPage {
        SidebarPage.resolveStored(storedPage)
    }

    private func select(_ page: SidebarPage) {
        // Deliberately instant, clamped on three layers:
        //
        //   1. The write hops out of the button-activation turn. macOS 26
        //      wraps Button actions in an animated transaction for the
        //      press/label state, and the click context is the only place
        //      the residual page-insertion interpolation lived: timer-driven
        //      swaps through this same method are pixel-clean. A next-hop
        //      write lands in a fresh transaction exactly like the timer
        //      path.
        //   2. The write itself carries an instant transaction
        //      (`animation = nil`, `disablesAnimations = true`) so any
        //      caller that skips the runloop hop still swaps clean.
        //   3. content/pageBody attach .transition(.identity) so a page's
        //      enter/exit is never interpolated, whatever drives it.
        //
        // In-page animations (LogCard auto-scroll, StatusHeroCard pulse)
        // own their transactions and are untouched. Rows also bypass the
        // system activation machinery entirely (InstantButtonStyle).
        var instant = Transaction()
        instant.animation = nil
        instant.disablesAnimations = true
        DispatchQueue.main.async {
            withTransaction(instant) { self.storedPage = page.rawValue }
        }
    }

    private func stepSelection(forward: Bool) {
        let all = SidebarPage.allCases
        guard let index = all.firstIndex(of: selection) else { return }
        let next = forward ? (index + 1) % all.count : (index + all.count - 1) % all.count
        select(all[next])
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            // Thin separator between sidebar and content. Both areas
            // read as almost the same material shade; a hairline beats
            // relying on color contrast.
            Rectangle()
                .fill(.separator.opacity(0.6))
                .frame(width: 1)
                .ignoresSafeArea()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: .all)
    }

    // MARK: - Sidebar

    /// The traffic lights float here. Their centers sit about 14pt below
    /// the window top; starting the first row at 44pt reads as "the
    /// lights belong to the sidebar's breathing room", which is what the
    /// reference windows do.
    private static let trafficLightInset: CGFloat = 44
    /// Sidebar width. Proportioned after the reference windows
    /// (Hand Mirror about 1/3, Dropover about 1/4).
    private static let sidebarWidth: CGFloat = 204

    /// The branding row's app icon. A bare `swift run` binary carries
    /// no icon asset, and `NSApp.applicationIconImage` then falls back
    /// to the generic "generic app" folder-style image (it read as a
    /// blue folder in self-captures). Brand with the real icon only
    /// when the bundle actually ships one; otherwise the row is
    /// text-only.
    private static let brandIcon: NSImage? = {
        let shipsIcon = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil
            || Bundle.main.path(forResource: "AppIcon", ofType: "icns") != nil
        return shipsIcon ? NSApp.applicationIconImage : nil
    }()

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            rows
                .padding(.top, Self.trafficLightInset)
                .padding(.horizontal, Design.Spacing.small)

            Spacer(minLength: 0)

            // A bare `swift run` binary has no version; the row then
            // renders just the name, which is fine.
            HStack(alignment: .center, spacing: Design.Spacing.small) {
                if let icon = Self.brandIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "TetherKit")
                        .font(.callout.weight(.medium))
                    if let version = Self.bundleVersion {
                        Text(verbatim: version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .foregroundStyle(.secondary)
            .padding(Design.Spacing.medium)
        }
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(.thinMaterial, ignoresSafeAreaEdges: .all)
    }

    /// The page rows.
    ///
    /// The container is focusable so Up/Down arrows cycle pages
    /// (`stepSelection`; the rows are hand-rolled buttons, so nothing
    /// does this for us). The system's focus chrome is suppressed
    /// (`.focusEffectDisabled()`), the selected row's fill is the
    /// visible cursor.
    ///
    /// Selected state is a rounded gray fill. Uses `primary` at low
    /// opacity instead of `.quaternary` because quaternary is nearly
    /// invisible on the material background (measured by eye in
    /// screenshots, not taste).
    private var rows: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(SidebarPage.allCases) { page in
                SidebarRow(
                    page: page,
                    isSelected: selection == page,
                    iconTint: SidebarPage.tint(for: page, status: model.status)
                ) {
                    select(page)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            stepSelection(forward: false)
            return .handled
        }
        .onKeyPress(.downArrow) {
            stepSelection(forward: true)
            return .handled
        }
    }

    // MARK: - Content area

    @ViewBuilder
    private var content: some View {
        if selection == .log {
            // The log page takes no page-level scroll: its list must
            // grow with the window (see LogPage). Height semantics,
            // including this page's padding, belong to the page.
            LogPage(model: model)
                .transition(.identity)
        } else {
            scrollablePage
                .transition(.identity)
        }
    }

    /// Heading for the current page. Throughput carries the LIVE badge
    /// in the trailing accessory (the card no longer renders one).
    @ViewBuilder
    private var pageHeading: some View {
        switch selection {
        case .throughput:
            SidebarPageHeading(title: selection.title) { throughputLiveBadge }
        default:
            SidebarPageHeading(title: selection.title)
        }
    }

    @ViewBuilder
    private var throughputLiveBadge: some View {
        if model.status.runState == .running {
            StatusBadge(text: L(.throughputLive), color: .green)
        }
    }

    /// Every page except the log shares this "heading + scrolling body"
    /// container.
    private var scrollablePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.large) {
                pageHeading
                pageBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Spacing.large)
            .padding(.top, Design.Spacing.medium + 4)
            .padding(.bottom, Design.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // No scrolling or bounce when the content fits.
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var pageBody: some View {
        // Every branch gets .transition(.identity): pages entering or
        // leaving here must not be interpolated (see select() for why,
        // and content above for the sibling boundary).
        switch selection {
        case .connection: ConnectionPage(model: model).transition(.identity)
        case .network: NetworkCard(model: model).transition(.identity)
        case .throughput: ThroughputCard(model: model).transition(.identity)
        // The log page branches at the content level above (no outer
        // scroll); this case only satisfies exhaustiveness.
        case .log: EmptyView()
        case .manage: ManagePage(model: model).transition(.identity)
        }
    }

    private static var bundleVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

/// Page heading: page title plus an optional trailing accessory view
/// (the LIVE badge, for one).
///
/// Shared by the shell's generic container and the log page (which
/// owns its own layout). Both must render the identical heading, so it
/// lives here instead of two hand-rolled HStacks.
struct SidebarPageHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(title: String,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
            Text(title)
                .font(.title2.weight(.semibold))
            Spacer(minLength: Design.Spacing.small)
            trailing()
        }
    }
}

/// One sidebar entry row.
///
/// Drawn the way native sidebars behave: light gray on hover, deeper
/// gray when selected. The icon is a white 12pt symbol inside a 22pt
/// rounded colored tile, the signature visual element of the
/// reference UIs.
private struct SidebarRow: View {
    let page: SidebarPage
    let isSelected: Bool
    let iconTint: Color
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Design.Spacing.small) {
                icon
                Text(page.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(InstantButtonStyle())
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var icon: some View {
        Image(systemName: page.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(iconTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.primary.opacity(0.08)
        }
        return isHovering ? Color.primary.opacity(0.04) : Color.clear
    }
}

/// A primitive button style that only performs the action: no activation
/// highlight machinery, no animated transaction around the action's view
/// updates. macOS 26's default activation wraps button actions in an
/// animated transaction; that is the click-only context the page-insertion
/// interpolation escaped through. Selected and hover styling is hand-drawn
/// in the row already.
private struct InstantButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .transaction { t in t.animation = nil }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { configuration.trigger() })
    }
}
