import SwiftUI
import TetherKitIPC

/// One page of the main window's sidebar.
///
/// Lives in `TetherKitUIModel` (a library target) instead of the
/// executable: a SwiftPM executable cannot be `@testable`-imported,
/// and the tint semantics below deserve unit tests.
///
/// The organizing rule carries over from the old ContentView layout:
/// separate "which device / how to get online" from "how it is running /
/// what went wrong". The sidebar turns that into spatial order:
/// Connection is the only place the user acts from, so it goes first;
/// observability pages (Throughput, Log) come later; admin tasks
/// (install/uninstall the privileged helper) happen a few times a year
/// and go last.
///
/// The order is fixed on purpose, not alphabetical. Sort key is
/// "how often you touch it", not a dictionary. Selection is remembered
/// via `@AppStorage` by `rawValue`, so RENAMING a case drops the
/// stored selection once, while reordering or adding pages does not.
/// Think before renaming.
public enum SidebarPage: String, CaseIterable, Identifiable, Hashable {
    case connection
    case network
    case throughput
    case log
    case manage

    public var id: String { rawValue }

    /// Restores a persisted selection: empty strings and rawValues of
    /// renamed pages fall back to `connection`, the natural home page.
    /// (Selection persists via `@AppStorage` by `rawValue`; reordering
    /// or adding cases does not disturb it.)
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

    /// SF Symbol for the page icon.
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
    /// recognizable visual cues in the reference UIs (Hand Mirror /
    /// Dropover); every page gets a fixed color.
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

    /// The Connection tile changes color with session state.
    ///
    /// The sidebar is always in view: while a session runs, even the icon
    /// turns green, so a glance confirms the connection is alive. Other
    /// pages keep fixed colors; state semantics belong to this page only.
    ///
    /// The decision is separated from its rendering on purpose: unit
    /// tests lock the decision (`accent`), while SwiftUI color equality
    /// is only compared for statics (dynamic NSColor-backed colors are
    /// not reliably comparable across constructions).
    enum Accent: Equatable {
        /// Keep the page's own fixed tile color.
        case fixed
        /// Session is live.
        case live
        /// Session failed.
        case failed
        /// Session is starting / stopping.
        case transitioning
    }

    /// Session-state → accent decision, framework-free.
    static func accent(for page: SidebarPage, status: SessionStatus) -> Accent {
        guard case .connection = page else { return .fixed }
        switch status.runState {
        case .running: return .live
        case .failed: return .failed
        case .starting, .stopping: return .transitioning
        case .idle, .stopped: return .fixed
        }
    }

    /// Renders the decision; `fixed` falls back to the page's own tint.
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
