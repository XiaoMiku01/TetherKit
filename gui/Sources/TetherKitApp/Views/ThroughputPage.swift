import SwiftUI
import TetherKitIPC

/// The "Throughput" page: live rate chart and cumulative counters.
///
/// The card's own title row is off here; the page header already says
/// "Throughput", and repeating it at the same level reads as a bug.
/// The LIVE badge moved from the card header to the right side of the
/// page header: it describes the whole page, not one grid cell.
struct ThroughputPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            SidebarPageHeading(title: L(.pageThroughputTitle)) {
                if model.status.runState == .running {
                    StatusBadge(text: L(.throughputLive), color: .green)
                }
            }
            ThroughputCard(model: model, showsTitleRow: false)
        }
    }
}
