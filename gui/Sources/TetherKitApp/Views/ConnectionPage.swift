import SwiftUI
import TetherKitIPC

/// The "Connection" page: the app's single point of action. Status
/// hero, environment warning (only on failure), device selection.
/// Network setup lives on the "Network" page. The only decision before
/// connecting is the device; every other decision makes sense once the
/// network interface exists.
struct ConnectionPage: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.gutter) {
            StatusHeroCard(model: model)
            EnvironmentWarningCard(environment: model.environment)
            DeviceCard(model: model)
        }
    }
}

/// Shown when the environment check fails; hidden when it passes, so
/// a healthy environment takes none of the user's attention.
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
