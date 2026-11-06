import SwiftUI
import TetherKitIPC

/// 「网络」页：DHCP / 静态 IP 的配置与回读。
///
/// 内容就是原 Dashboard 左栏的那张卡，一字未改地搬进自己的页面 —— 它以前
/// 挤在半栏里排两列表单，如今有 640pt 的全宽可以用（踩过的「整页高度预算」
/// 约束随之消失，表单与回读值即使同时展开也不必再为谁让路）。
struct NetworkPage: View {
    @Bindable var model: AppModel

    var body: some View {
        NetworkCard(model: model)
    }
}
