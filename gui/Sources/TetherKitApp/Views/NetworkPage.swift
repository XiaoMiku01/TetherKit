import SwiftUI
import TetherKitIPC

/// The "Network" page: DHCP / static IP configuration and live readback.
///
/// The card from the old dashboard's left column, moved into its own
/// page without changing its internals. It used to fit a two-column
/// form in half a window column; it now gets the full 640pt width, so
/// the "whole page height budget" constraint is gone and the form and
/// the readback values can both expand without negotiating.
struct NetworkPage: View {
    @Bindable var model: AppModel

    var body: some View {
        NetworkCard(model: model)
    }
}
