import SwiftUI
import TetherKitIPC

/// One page of the main window's sidebar.
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
/// via `@SceneStorage` by `rawValue`, so RENAMING a case drops the
/// stored selection once, while reordering or adding pages does not.
/// Think before renaming.
enum SidebarPage: String, CaseIterable, Identifiable, Hashable {
    case connection
    case network
    case throughput
    case log
    case manage

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .connection: return .pageConnectionTitle
        case .network: return .pageNetworkTitle
        case .throughput: return .pageThroughputTitle
        case .log: return .pageLogTitle
        case .manage: return .pageManageTitle
        }
    }

    var title: String { L(titleKey) }

    /// SF Symbol for the page icon.
    var symbol: String {
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
    var tint: Color {
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
    static func tint(for page: SidebarPage, status: SessionStatus) -> Color {
        guard case .connection = page else { return page.tint }
        switch status.runState {
        case .running: return .green
        case .failed: return .red
        case .starting, .stopping: return .orange
        case .idle, .stopped: return page.tint
        }
    }
}
