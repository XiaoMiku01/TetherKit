import XCTest
import SwiftUI
import TetherKitIPC
@testable import TetherKitUIModel

/// Locks the sidebar page semantics: the per-run-state color of the
/// Connection tile ("the icon backs the glance") and the persisted
/// selection resolution.
///
/// The state→color semantics are asserted at the decision level
/// (`Accent`), since SwiftUI colors backed by dynamic NSColors are
/// not reliably comparable across constructions; spot checks cover
/// the static colors (`green`/`red`/`orange`), which compare exactly.
final class SidebarPageTests: XCTestCase {

    // MARK: Tint decision

    private func status(_ runState: RunState) -> SessionStatus {
        var snapshot = SessionStatus.idle
        snapshot.runState = runState
        return snapshot
    }

    /// The exhaustive state reference. Written without `default` on
    /// purpose: a future RunState case breaks compilation here, which
    /// forces its accent decision to be decided rather than inherited.
    private func expectedAccent(_ runState: RunState) -> SidebarPage.Accent {
        switch runState {
        case .running: return .live
        case .failed: return .failed
        case .starting, .stopping: return .transitioning
        case .idle, .stopped: return .fixed
        }
    }

    private let everyRunState: [RunState] =
        [.idle, .starting, .running, .stopping, .stopped, .failed]

    func testConnectionTileTracksRunState() {
        for runState in everyRunState {
            XCTAssertEqual(
                SidebarPage.accent(for: .connection, status: status(runState)),
                expectedAccent(runState),
                "connection tile with runState \(runState.rawValue)")
        }
    }

    func testNonConnectionTilesIgnoreSessionState() {
        for page in SidebarPage.allCases where page != .connection {
            for runState in everyRunState {
                XCTAssertEqual(
                    SidebarPage.accent(for: page, status: status(runState)),
                    .fixed,
                    "\(page.rawValue) must keep its fixed tint under \(runState.rawValue)")
            }
        }
    }

    func testAccentColorsRenderAsLocked() {
        // Static SwiftUI colors compare exactly; the `fixed` case
        // renders its fallback verbatim.
        XCTAssertEqual(SidebarPage.accentColor(.live, fallback: .black), .green)
        XCTAssertEqual(SidebarPage.accentColor(.failed, fallback: .black), .red)
        XCTAssertEqual(SidebarPage.accentColor(.transitioning, fallback: .black), .orange)
        XCTAssertEqual(SidebarPage.accentColor(.fixed, fallback: .blue), .blue)
        XCTAssertEqual(SidebarPage.accentColor(.fixed, fallback: Color(nsColor: .systemGray)),
                       Color(nsColor: .systemGray))
    }

    func testConnectionTileBecomesGreenWhenRunning() {
        // The user-visible rule, asserted end to end on the static
        // color the decision renders.
        XCTAssertEqual(
            SidebarPage.tint(for: .connection, status: status(.running)), .green)
        XCTAssertEqual(
            SidebarPage.tint(for: .connection, status: status(.failed)), .red)
    }

    // MARK: Persisted selection

    func testStoredSelectionRoundTrips() {
        for page in SidebarPage.allCases {
            XCTAssertEqual(SidebarPage.resolveStored(page.rawValue), page)
        }
    }

    func testUnknownOrEmptyStoredSelectionFallsBackToConnection() {
        XCTAssertEqual(SidebarPage.resolveStored(nil), .connection)
        XCTAssertEqual(SidebarPage.resolveStored(""), .connection)
        XCTAssertEqual(SidebarPage.resolveStored("bogus"), .connection)
        XCTAssertEqual(SidebarPage.resolveStored("Connection"), .connection,
                       "resolution is case-sensitive rawValue matching")
    }

    func testRenameEdgeCaseDocumentedByResolve() {
        // "manage" is a real case; a renamed-away value ("settings")
        // must not resurrect. Guards against resolveStored ever
        // becoming a fuzzy/heuristic lookup.
        XCTAssertEqual(SidebarPage.resolveStored("settings"), .connection)
    }
}
