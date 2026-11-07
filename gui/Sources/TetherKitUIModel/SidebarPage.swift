import SwiftUI
import TetherKitIPC

/// One page of the main window's sidebar.
///
/// Lives in `TetherKitUIModel` because a SwiftPM executable cannot be
/// `@testable`-imported and the tint semantics deserve unit tests.
/// Order is by how often the user reaches for a page: Connection is
/// where actions happen, Throughput/Log are for watching, Manage is
/// rare, so each step down is one step less frequent.
///
/// Selection persists via `@AppStorage` by `rawValue`: renaming a case
/// drops the stored selection once; reordering or adding cases does
/// not. Think before renaming.
public enum SidebarPage: String, CaseIterable, Identifiable, Hashable {
    case connection
    case network
    case throughput
    case log
    case manage

    public var id: String { rawValue }

    /// Restores a persisted selection: empty strings and rawValues of
    /// renamed pages fall back to `connection`, the natural home page.
    public static func resolveStored(_ storedValue: String?) -> SidebarPage {
        storedValue.flatMap(SidebarPage.init(rawValue:)) ?? .connection
    }

    public var titleKey: L10nKey {
        switch self {
        case .connection: return .pageConnectionTitle
        case .network: return .pageNetworkTitle
        case .throughput: return .pageThroughputTitle
        case .log: return .pageLogTitle
        case .manage: return .pageManageTitle
        }
    }

    public var title: String { L(titleKey) }

    public var symbol: String {
        switch self {
        case .connection: return "cable.connector"
        case .network: return "network"
        case .throughput: return "chart.xyaxis.line"
        case .log: return "scroll"
        case .manage: return "wrench.and.screwdriver"
        }
    }

    /// Tile color. A colored tile behind each icon is one of the most
    /// recognizable visual cues in the reference UIs; every page is
    /// fixed, except Connection's, which `tint(for:status:)` drives
    /// with the session state.
    public var tint: Color {
        switch self {
        case .connection: return .blue
        case .network: return .teal
        case .throughput: return .indigo
        case .log: return .brown
        case .manage: return Color(nsColor: .systemGray)
        }
    }
}

extension SidebarPage {

    /// The Connection tile's color-with-session-state decision:
    /// `fixed` keeps the page's own tint; the other cases carry the
    /// session states (see `accentColor`).
    ///
    /// The sidebar stays in view while a session runs, so the tile
    /// (icon too) confirms at a glance that the connection is alive.
    /// Other pages keep fixed colors; state semantics belong to this
    /// page only.
    ///
    /// Decision and rendering are separate so tests can lock the
    /// decision (`accent`); SwiftUI color equality is compared only
    /// for static colors (dynamic NSColor-backed colors are not
    /// reliably comparable across constructions).
    enum Accent: Equatable {
        case fixed
        case live
        case failed
        case transitioning
    }

    static func accent(for page: SidebarPage, status: SessionStatus) -> Accent {
        guard case .connection = page else { return .fixed }
        switch status.runState {
        case .running: return .live
        case .failed: return .failed
        case .starting, .stopping: return .transitioning
        case .idle, .stopped: return .fixed
        }
    }

    /// Renders the decision; the `fixed` case returns its `fallback`.
    static func accentColor(_ accent: Accent, fallback: Color) -> Color {
        switch accent {
        case .fixed: return fallback
        case .live: return .green
        case .failed: return .red
        case .transitioning: return .orange
        }
    }

    /// The row's tile color: session-state driven for the Connection
    /// page, the page's own fixed color everywhere else.
    public static func tint(for page: SidebarPage, status: SessionStatus) -> Color {
        accentColor(accent(for: page, status: status), fallback: page.tint)
    }
}
