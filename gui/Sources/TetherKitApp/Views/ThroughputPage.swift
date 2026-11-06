import SwiftUI

/// The "Throughput" page: live rate chart and cumulative counters.
///
/// The page header (SidebarShell) already reads "Throughput" and
/// carries the LIVE badge; this page is just the card.
struct ThroughputPage: View {
    @Bindable var model: AppModel

    var body: some View {
        ThroughputCard(model: model)
    }
}
