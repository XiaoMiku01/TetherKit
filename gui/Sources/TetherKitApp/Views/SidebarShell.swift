import SwiftUI
import TetherKitIPC

/// 主窗口的侧边栏 + 内容区框架。
///
/// 样式对齐参考 UI（Hand Mirror / Dropover 那一类设置窗）：左侧一列
/// 「彩色方块图标 + 页面名」的入口，右侧是带页标题的滚动内容。标题栏隐藏
/// （`.windowStyle(.hiddenTitleBar)`），红绿黄三个灯浮在侧边栏上方 ——
/// 所以侧边栏顶部留白要用 `trafficLightInset` 避开它们。
///
/// ★ 为什么是手写侧边栏而不是 NavigationSplitView ★
///
///   旧布局 ContentView 刻意不用侧边栏（「这个 App 只有一件事可做」）。
///   改成页面分区后侧边栏成立了，但 `NavigationSplitView` 的侧边栏自带
///   可折叠行为与系统选择样式，做不出参考 UI 这种固定宽 + 彩色图标的观感；
///   而本 App 不需要折叠（只有 5 个页面，全展示）。
///   因此手写：宽度固定，选中态与悬停态自己画，代价小且可控。
struct SidebarShell: View {
    @Bindable var model: AppModel

    /// 记住用户停在哪一页（属窗口场景，随窗口恢复）。存的是 rawValue。
    @SceneStorage("tetherkit.sidebar.page") private var storedPage: String = ""

    private var selection: SidebarPage {
        SidebarPage(rawValue: storedPage) ?? .connection
    }

    private func select(_ page: SidebarPage) {
        withAnimation(.smooth(duration: 0.15)) { storedPage = page.rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            // 内容区与侧边栏之间的一道细线：两个区域的底色都被 material
            // 弄得很接近，靠线条分界比靠色差可靠。
            Rectangle()
                .fill(.separator.opacity(0.6))
                .frame(width: 1)
                .ignoresSafeArea()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: .all)
    }

    // MARK: - 侧边栏

    /// 红绿黄三个灯浮在这里。灯的中心大约在窗口顶部 14pt 处，往下留 44pt
    /// 起第一行，视觉上是「灯属于侧边栏的空气」，多数参考窗都是这个做法。
    private static let trafficLightInset: CGFloat = 44
    /// 侧边栏宽度。参考窗的比例对齐（Hand Mirror 约 1/3，Dropover 约 1/4）。
    private static let sidebarWidth: CGFloat = 204

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            rows
                .padding(.top, Self.trafficLightInset)
                .padding(.horizontal, Design.Spacing.small)

            Spacer(minLength: 0)

            // 底部的 App 身份行（对齐参考 App 的做法：图标 + 名字 + 版本，
            // 低调、不可交互）。`swift run` 裸可执行文件没有版本号，藏半行无妨。
            HStack(alignment: .center, spacing: Design.Spacing.small) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "TetherKit")
                        .font(.callout.weight(.medium))
                    if let version = Self.bundleVersion {
                        Text(verbatim: version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .foregroundStyle(.secondary)
            .padding(Design.Spacing.medium)
        }
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(.thinMaterial, ignoresSafeAreaEdges: .all)
        .animation(.smooth(duration: 0.25), value: model.status.runState)
    }

    /// 页面项列表。
    ///
    /// 选中态是圆角灰底 —— 用 `primary` 的低透明度而不是 `.quaternary`，
    /// 因为在 material 底上 quaternary 几乎不可见（实测观感）。
    private var rows: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(SidebarPage.allCases) { page in
                SidebarRow(
                    page: page,
                    isSelected: selection == page,
                    iconTint: SidebarPage.tint(for: page, status: model.status)
                ) {
                    select(page)
                }
            }
        }
    }

    // MARK: - 内容区

    /// 当前页正文 + 页标题套进的滚动容器。
    ///
    /// 内容有最大宽度（`contentWidthCap`）：窗口拉得再宽也就如参考 App 一样
    /// 排在左侧，不对着满屏拉伸卡片 —— 卡片无限宽会让每个选择控件都跟文字
    /// 离得很远，读起来反而费劲。
    private static let contentWidthCap: CGFloat = 640

    @ViewBuilder
    private var content: some View {
        if selection == .log {
            // 日志页不走页面级滚动：列表要随窗口长高（理由见 LogPage），
            // 高度语义（含 internal padding）由这一页自带。
            LogPage(model: model)
        } else {
            scrollablePage
        }
    }

    /// 除日志页外，所有页面共用「页头 + 滚动正文」的容器。
    private var scrollablePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.large) {
                SidebarPageHeading(title: selection.title)
                pageBody
            }
            .frame(maxWidth: Self.contentWidthCap, alignment: .leading)
            .padding(.horizontal, Design.Spacing.large)
            .padding(.top, Design.Spacing.medium + 4)
            .padding(.bottom, Design.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // 与旧布局同一个哲学：内容放得下就不滚、不回弹。
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var pageBody: some View {
        switch selection {
        case .connection: ConnectionPage(model: model)
        case .network: NetworkPage(model: model)
        case .throughput: ThroughputPage(model: model)
        // 日志在 content 层走专属分支（不要外层滚动）；switch 需要穷尽，
        // 落一个空视图纯粹是语言义务，不是「还没做」的占位。
        case .log: EmptyView()
        case .manage: ManagePage(model: model)
        }
    }

    private static var bundleVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

/// 页头：页面标题 + 可选的右侧附属视图（如「实时」徽标）。
///
/// 供 shell 的通用容器与不走容器的日志页共用，两处的标题排版必须一字不差；
/// 因此做成组件而不是各自手写一层 HStack。
struct SidebarPageHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(title: String,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.small) {
            Text(title)
                .font(.title2.weight(.semibold))
            Spacer(minLength: Design.Spacing.small)
            trailing()
        }
    }
}

/// 侧边栏里一行页面入口。
///
/// 交互按原生侧边栏的习惯画：悬停浅灰、选中更深；图标是 22pt 彩色圆角方块
/// 内嵌白色小 symbol —— 这是参考 UI 的签名视觉元素。
private struct SidebarRow: View {
    let page: SidebarPage
    let isSelected: Bool
    let iconTint: Color
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Design.Spacing.small) {
                icon
                Text(page.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var icon: some View {
        Image(systemName: page.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(iconTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.primary.opacity(0.08)
        }
        return isHovering ? Color.primary.opacity(0.04) : Color.clear
    }
}
