import SwiftUI
import TetherKitIPC

/// 「日志」页。
///
/// 与其他页有一个结构差异：**不走页面级 ScrollView**。日志的核心价值之一是
/// 「窗口越大看到的越多」—— 列表应当随窗口长高，而不是被外层滚动层量成
/// 一个固定理想尺寸后在页脚剩余一片空白。其它页的滚动由 `SidebarShell`
/// 统一接管，这一页自带高度语义（见 LogCard 的 `fillsAvailableHeight`），
/// 因此在 shell 里走单独分支。
struct LogPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            SidebarPageHeading(title: L(.pageLogTitle))
            LogCard(model: model, fillsAvailableHeight: true)
        }
        .padding(.horizontal, Design.Spacing.large)
        .padding(.top, Design.Spacing.medium + 4)
        .padding(.bottom, Design.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
