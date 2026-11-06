import SwiftUI
import TetherKitIPC

/// 主窗口侧边栏里的一个页面。
///
/// 页面的组织原则延续 ContentView 旧布局的一句注释：**把「用哪台设备 / 怎么上网」
/// 跟「跑得怎么样 / 出了什么事」分开**。侧边栏把这句升级成空间上的分区 ——
/// 连接是唯一的操作重心，自然排第一；观测类页面（吞吐、日志）往后排；
/// 管理类动作（装 / 卸特权组件）一年也就碰几次，放最后。
///
/// 页面顺序是刻意固定的：不要 alphabetical —— 排序的依据是「多久碰一次」，
/// 不是字典。选项的记忆（`@SceneStorage`）按 `rawValue` 存，因此**改名会
/// 丢一次选中记忆**，而调整位置 / 新增页面不会 —— 改名前想一下。
enum SidebarPage: String, CaseIterable, Identifiable, Hashable {
    case connection
    case network
    case throughput
    case log
    case manage

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .connection: return .pageConnectionTitle
        case .network: return .pageNetworkTitle
        case .throughput: return .pageThroughputTitle
        case .log: return .pageLogTitle
        case .manage: return .pageManageTitle
        }
    }

    var title: String { L(titleKey) }

    /// 页面图标的 SF Symbol。
    var symbol: String {
        switch self {
        case .connection: return "cable.connector"
        case .network: return "network"
        case .throughput: return "chart.xyaxis.line"
        case .log: return "scroll"
        case .manage: return "wrench.and.screwdriver"
        }
    }

    /// 图标底的配色。彩色方块图标是参考 UI（Hand Mirror / Dropover）最显眼的
    /// 视觉语言之一，每页一个固定色。
    var tint: Color {
        switch self {
        case .connection: return .blue
        case .network: return .teal
        case .throughput: return .indigo
        case .log: return .brown
        case .manage: return Color(nsColor: .systemGray)
        }
    }
}

extension SidebarPage {

    /// 「连接」页图标随会话状态变色的那条规则。
    ///
    /// 侧边栏是常驻视野：会话在跑时连图标都泛绿，余光就能确认连接还活着。
    /// 其余页面是固定色 —— 状态语义只属于连接这一页。
    static func tint(for page: SidebarPage, status: SessionStatus) -> Color {
        guard case .connection = page else { return page.tint }
        switch status.runState {
        case .running: return .green
        case .failed: return .red
        case .starting, .stopping: return .orange
        case .idle, .stopped: return page.tint
        }
    }
}
