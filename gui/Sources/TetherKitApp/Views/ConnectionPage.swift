import SwiftUI
import TetherKitIPC

/// 侧边栏布局下的「连接」页 —— 整个 App 的操作重心。
///
/// 从上到下：状态横幅（现在通不通、要不要断开）→ 环境警告（不合格才出现）
/// → 设备选择（用哪台设备、MTU/MAC 想怎么连）。上网方式的配置已拆去
/// 「网络」页 —— 连接前唯一要做的决定就是选好设备，其余决定等网卡建出来
/// 再做才有意义。
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

/// 环境预检不合格时的警告。合格时不显示 —— 一切正常时不该占用户的注意力。
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
