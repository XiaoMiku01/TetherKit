import SwiftUI
import TetherKitIPC

/// The "Log" page.
///
/// One structural difference from every other page: no page-level
/// ScrollView. A core value of the log is "a bigger window sees more
/// entries". The list should grow with the window, not get measured at
/// a fixed ideal size by an outer scroll container and leave blank
/// space under the page. SidebarShell handles scrolling for the other
/// pages; this page owns its height semantics (see LogCard) and
/// branches separately in the shell.
struct LogPage: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            SidebarPageHeading(title: L(.pageLogTitle))
            LogCard(model: model)
        }
        // Same paddings as SidebarShell.scrollablePage: the two page
        // containers must match edge to edge.
        .padding(.horizontal, Design.Spacing.large)
        .padding(.top, Design.Spacing.medium + 4)
        .padding(.bottom, Design.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
