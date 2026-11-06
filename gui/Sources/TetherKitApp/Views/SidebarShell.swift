import SwiftUI
import TetherKitIPC

/// Main window frame: sidebar plus content area.
///
/// Styling follows the reference UI set (settings-style windows like
/// Hand Mirror / Dropover): a left column of "colored tile icon + page
/// name" entries, and headered scrolling content on the right. The
/// title bar is hidden (`.windowStyle(.hiddenTitleBar)`), so the three
/// traffic lights float above the sidebar. The sidebar's top inset
/// (`trafficLightInset`) keeps clear of them.
///
/// Why a hand-rolled sidebar instead of NavigationSplitView:
///
///   The old ContentView layout skipped a sidebar on purpose ("this app
///   does one thing"). With page topics that argument is gone, but
///   NavigationSplitView demands collapsibility and the system's
///   selection styling, and cannot produce the fixed-width,
///   colored-tile look of the reference UIs. This app does not need
///   collapsing (5 pages, all shown). Handling width, selected and
///   hover states by hand costs little and stays in control.
struct SidebarShell: View {
    @Bindable var model: AppModel

    /// Last page the user was on, persisted via UserDefaults and
    /// restored on launch. Stores the rawValue. (The main window is a
    /// plain AppKit window now, not a SwiftUI scene, so @SceneStorage
    /// has no scene to write to; @AppStorage is the drop-in.)
    @AppStorage("tetherkit.sidebar.page") private var storedPage: String = ""

    private var selection: SidebarPage {
        SidebarPage(rawValue: storedPage) ?? .connection
    }

    private func select(_ page: SidebarPage) {
        withAnimation(.smooth(duration: 0.15)) { storedPage = page.rawValue }
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            rows
                .padding(.top, Self.trafficLightInset)
                .padding(.horizontal, Design.Spacing.small)

            Spacer(minLength: 0)

            // App identity row at the bottom (matching the reference
            // apps: icon + name + version, quiet, not interactive).
            // A bare `swift run` binary has no version; half a hidden
            // line is fine.
            HStack(alignment: .center, spacing: Design.Spacing.small) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
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
        .animation(.smooth(duration: 0.25), value: model.status.runState)
    }

    /// The page rows.
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
    }

    // MARK: - Content area

    /// Scroll container wrapping the current page body and its heading.
    ///
    /// Content has a max width (`contentWidthCap`): however wide the
    /// window gets, the cards stay in the left region as the reference
    /// apps do. Unbounded cards put every picker far from its label
    /// text; wide spacing reads worse, not better.
    private static let contentWidthCap: CGFloat = 640

    @ViewBuilder
    private var content: some View {
        if selection == .log {
            // The log page takes no page-level scroll: its list must
            // grow with the window (see LogPage). Height semantics,
            // including this page's padding, belong to the page.
            LogPage(model: model)
        } else {
            scrollablePage
        }
    }

    /// Every page except the log shares this "heading + scrolling body"
    /// container.
    private var scrollablePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.large) {
                SidebarPageHeading(title: selection.title)
                pageBody
            }
            .frame(maxWidth: Self.contentWidthCap, alignment: .leading)
            .padding(.horizontal, Design.Spacing.large)
            .padding(.top, Design.Spacing.medium + 4)
            .padding(.bottom, Design.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Same philosophy as the old layout: no scrolling or bounce
        // when the content fits.
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var pageBody: some View {
        switch selection {
        case .connection: ConnectionPage(model: model)
        case .network: NetworkPage(model: model)
        case .throughput: ThroughputPage(model: model)
        // The log page branches at the content level above (no outer
        // scroll). The switch still needs to be exhaustive; an empty
        // view here exists to satisfy the language, not as a "not done
        // yet" stub.
        case .log: EmptyView()
        case .manage: ManagePage(model: model)
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
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var icon: some View {
        Image(systemName: page.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(iconTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.primary.opacity(0.08)
        }
        return isHovering ? Color.primary.opacity(0.04) : Color.clear
    }
}
