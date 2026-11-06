import SwiftUI
import TetherKitIPC

/// The "Connection" page under the sidebar layout: the app's single
/// point of action.
///
/// Top to bottom: status hero (running or not, disconnect if needed)
/// then environment warning (only when the environment fails) then
/// device selection (which device, MTU/MAC). Network setup moved to the
/// "Network" page. The only decision before connecting is the device;
/// every other decision makes sense once the network interface exists.
struct ConnectionPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.gutter) {
            StatusHeroCard(model: model)
            EnvironmentWarningCard(environment: model.environment)
            DeviceCard(model: model)
        }
    }
}

/// Warning shown when the environment check fails. Hidden when it
/// passes: when nothing is wrong, do not take any of the user's
/// attention.
struct EnvironmentWarningCard: View {
    let environment: EnvironmentReport?

    var body: some View {
        if let environment, !environment.sysctlsOK {
            Card(title: L(.sysctlNeedsFixTitle), systemImage: "exclamationmark.triangle.fill") {
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    Text(L(.sysctlNeedsFixBody))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(environment.sysctlDetail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Design.Spacing.small)
                        .background(.quaternary.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: Design.Radius.control))
                }
            }
        }
    }
}
