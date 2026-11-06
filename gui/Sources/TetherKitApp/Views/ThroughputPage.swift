import SwiftUI
import TetherKitIPC

/// 「吞吐」页：实时速率图表与累计计数器。
///
/// 卡片自带标题行被关掉（页头已经写着「吞吐」，同一层级出现两次很怪），
/// 而「实时」徽标从卡片头搬到页头右侧 —— 它表明的性质属于整页，
/// 不属于卡里的某一格。
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
