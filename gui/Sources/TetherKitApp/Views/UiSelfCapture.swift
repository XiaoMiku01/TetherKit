import AppKit
import SwiftUI

// 视觉迭代的自截工具（dev 用）。
//
// 背景：给 App 窗口截图走系统 Screen Recording 权限，在无头 / CI / 代理会话里
// 拿不到。**App 截自己的窗口**不受该权限约束 —— 直接用窗口号把自己画进位图
// （CGWindowListCreateImage 支持「选自己的窗口」，等价于窗口截图的效果）。
//
// 调用约定（调试用启动参数）：
//
//   ./TetherKit -SelfCapture /tmp/out.png -TetherKitLanguagePreference chinese
//
//   * `-SelfCapture <path>`：窗口稳定后截窗写 PNG，随即 terminate；
//   * 语言也用参数域 UserDefaults 强制（`-TetherKitLanguagePreference
//     <chinese|english>`，argument domain 的优先级高于普通存储）。
//
// 这个文件只有几十行，换来的是「改一版界面 → 自动截窗 → 看 PNG」这个循环
// 不依赖任何屏幕权限。退役条件：整个自截流程被 CI 里某个正经方案替代。

/// 自截的驱动逻辑。
enum UiSelfCapture {

    /// 解析启动参数里的输出路径；没有该参数时返回 nil（正常启动）。
    static func requestedOutputPath() -> String? {
        let arguments = CommandLine.arguments
        return arguments.firstIndex(of: "-SelfCapture")
            .flatMap { index in index + 1 < arguments.count ? arguments[index + 1] : nil }
    }

    /// 窗口就绪后安排一次截窗 + 退出。
    static func schedule(_ window: NSWindow, outputPath: String) {
        // 留时间给布局、语言恢复与首个状态轮询：1.5 秒后画面完全稳定。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            capture(window, to: outputPath)
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ window: NSWindow, to path: String) {
        // 首选：按窗口号整窗位图（`boundsIgnoreFraming` 把窗口圆角外的
        // 投影留白裁掉，方便逐像素比对外观）。
        let id = CGWindowID(window.windowNumber)
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                            [.boundsIgnoreFraming, .bestResolution]) {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                return
            }
        }
        // 回退：内容视图的视图树缓存渲染。SwiftUI 的 Hosting 视图支持这条
        // 路径；material 模糊会被压成近似底色，足够判断布局。
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// 视图挂在窗口上时检查并挂起一次自截任务。
///
/// 需要一个真正放进窗口的视图才能摸到 NSWindow；零尺寸探针不影响布局。
/// 主窗口根视图上 `.background(SelfCaptureProbe())` 挂一次即可。
struct SelfCaptureProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !Self.scheduled else { return }
            Self.scheduled = true
            guard let path = UiSelfCapture.requestedOutputPath() else { return }
            UiSelfCapture.schedule(window!, outputPath: path)
        }

        /// SwiftUI 的视图会反复被装进 / 移出窗口（语言切换就会整树重建），
        /// 一次截窗任务只排一次。
        private static var scheduled = false
    }
}

extension View {

    /// 窗口若处于自截模式（`-SelfCapture` 启动参数），窗口就绪后自动截窗写 PNG。
    func handleSelfCaptureRequest() -> some View {
        background(SelfCaptureProbe())
    }
}
