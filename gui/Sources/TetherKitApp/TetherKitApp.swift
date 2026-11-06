import AppKit
import SwiftUI
import TetherKitIPC

/// TetherKit 的图形界面入口。
///
/// App 以**普通用户身份**运行，不需要任何特权。所有需要 root 的事（建虚拟网卡、
/// 开 BPF、配 IP）都交给 tetherkit-helper，每次调用附带一份用户确认过的授权
/// 凭据。详见 docs/GUI-ARCHITECTURE.md。
///
/// ★ 后台运行模式 ★
///
///   关闭主窗口不退出：App 退到「仅菜单栏」（accessory 激活策略，程序坞图标
///   一并隐藏），菜单栏项继续显示实时速率。会话本来就跑在 helper 里，App 的
///   存在与否都不影响它 —— 但只要 App 活着，用户就有一个随时能看一眼的入口。
///
///   轮询在窗口关闭后**不**停（菜单栏靠它喂数据），只是在「窗口关着且会话
///   没跑」时放慢到 2 秒一次，见 AppModel.pollDelay。
@main
struct TetherKitApplication: App {
    @State private var model = AppModel()

    init() {
        // CI 冒烟与手动补建用的模式：建完 Finder 别名即退，不进 GUI。
        // 恒 exit 0 —— 别名建不上（受管机器之类）不该把流程判失败，结果打给
        // stdout。（brew 的 postinstall 也在沙箱里、写不了 /Applications ——
        // 实测确认 —— 所以正常安装路径靠下面的首次启动自动建立。）
        if CommandLine.arguments.dropFirst().contains("--install-finder-alias") {
            print(FinderAlias.ensure(for: Bundle.main.bundleURL))
            exit(0)
        }
        // macOS 26 实测踩坑：**裸可执行**（swift build 的产物，没有 bundle id）
        // 启动时激活策略是 .prohibited，而 SwiftUI 对「无激活权」的 App 不实例化
        // Window 场景的窗口 —— 主窗口永远不出现，只能靠菜单栏「打开主窗口」救回
        // （那个按钮走 openWindow 前先把策略改回 .regular，所以能用）。
        // 打包的 .app 由 LaunchServices 给 .regular，这里永远不会命中；补一次
        // 只服务裸可执行的启动自检。插桩证据见 AGENTS.md 第 7 节。
        // NSApp 这个全局是隐式拆包的可选值，NSApplication 建好之前是 nil，
        // 这里必须用 NSApplication.shared 显式初始化 AppKit。
        if NSApplication.shared.activationPolicy() == .prohibited {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        // 正常启动：后台顺手校一遍 —— 缺了就补，brew upgrade 换了 Cellar
        // 路径后目标漂移也会被重写。
        let bundleURL = Bundle.main.bundleURL
        Task.detached(priority: .utility) {
            FinderAlias.ensure(for: bundleURL)
        }
    }

    var body: some Scene {
        // 菜单栏常驻项：图标 + 实时速率。
        //
        // 用 .window 风格给一块小面板而不是一列菜单 —— 速率、地址这些信息是要
        // 「看」的，不是要「选」的，菜单条目装不下。
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        mainScene
    }

    /// 主窗口场景。
    ///
    /// 用 Window 而不是 WindowGroup：这是一个「设备连接面板」，开多个窗口
    /// 没有意义，反而会让多个实例同时轮询同一个 helper。
    ///
    /// 标题栏隐藏（`.hiddenTitleBar`）：侧边栏从窗口顶贯通到底，红绿黄三灯
    /// 直接浮在侧边栏上 —— 参考设置窗（Hand Mirror / Dropover）的标准做法。
    /// 窗口仍可从顶部的隐藏标题栏区域拖动；`SceneBuilder` 不支持
    /// `if #available` 分支，所以 macOS 15 的 `windowBackgroundDragBehavior`
    /// （按背景拖动）要等平台下限提高才能加。
    private var mainScene: some Scene {
        Window("TetherKit", id: "main") {
            MainWindowRoot(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: Design.Window.defaultWidth, height: Design.Window.defaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            // 「新建窗口」对单窗口应用没有意义，去掉免得用户点了没反应。
            CommandGroup(replacing: .newItem) {}
            // 「检查更新…」放在 App 菜单「关于」下面的惯例位置。
            // 只查不换 —— 原因见 UpdateChecker.swift 的类型注释。
            CommandGroup(after: .appInfo) { AppMenuItems(model: model) }
        }
    }
}

/// App 菜单里 TetherKit 自己的那几项。
///
/// ★ 为什么要包成一个 View，而不是把 Button 直接摊在 CommandGroup 里 ★
///
///   摊开写的话，每个 Button 的标签各自是一个独立的表达式，SwiftUI 只会在
///   「它依赖的东西变了」时重算。而文案来自全局查表，`L(.menuCheckForUpdates)`
///   不依赖任何 @Observable 属性 —— 于是切完语言，语言菜单自己变了（它读了
///   `languagePreference`），旁边的「检查更新…」却还是旧语言。实测确认过。
///
///   包成一个 View 并在体里读一次 `languageRevision`，整组就一起重算了。
private struct AppMenuItems: View {
    var model: AppModel

    var body: some View {
        // 读它就是为了建立依赖，值本身用不上。
        let _ = model.languageRevision

        Button(L(.menuCheckForUpdates)) {
            Task { await model.checkForUpdates() }
        }
        // 语言放在 App 菜单而不是主界面上：切语言是「设置一次就再也不碰」的
        // 动作，而主界面的高度预算早就见底了（见 ContentView 里管理行那段说明），
        // 不该为它再挤出一行。
        LanguageMenu(model: model)
    }
}

/// App 菜单里的语言选择。
///
/// 每一项都直接写母语名字（「中文」/「English」），不跟随当前界面语言翻译 ——
/// 语言菜单是给「现在看不懂界面」的人用的，把选项也翻译掉就等于没有出口。
/// 「跟随系统」是唯一例外：它描述的是行为而非语言，所以随界面走。
private struct LanguageMenu: View {
    var model: AppModel

    var body: some View {
        Menu(L(.languageMenuTitle)) {
            Picker(L(.languageLabel), selection: Bindable(model).languagePreference) {
                Text(L(.languageSystem)).tag(LanguagePreference.system)
                Text(verbatim: "中文").tag(LanguagePreference.chinese)
                Text(verbatim: "English").tag(LanguagePreference.english)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// 主窗口的根视图：内容 + 生命周期钩子 + 「擅自复活」拦截。
///
/// ★ 为什么需要拦截 ★
///
///   实测（打包版，macOS 26）：App 处于仅菜单栏模式时点菜单栏图标，SwiftUI 会在
///   面板打开的同时**擅自重建整个 Window 场景** —— 主窗口毫无来由地冒回来，把
///   面板压在底下。这不走 `applicationShouldHandleReopen`（插桩确认从未被调用，
///   SwiftUI 生命周期不转发它），所以没有干净的委托口子可堵。
///
///   对策是在结果端把关：窗口每次出现时问 AppModel「这次展示是我们自己要求的
///   吗」。只有两种合法来源 —— App 启动、用户点了「打开主窗口」—— 两处都会先在
///   模型上登记。没登记过的出现就是擅自复活，当场 dismiss，激活策略保持
///   accessory 不动。
///
///   代价：在仅菜单栏模式下双击访达里的 App 图标不会弹出主窗口（那次重建同样
///   会被拦掉）。这是权衡后的结果 —— 菜单栏是唯一入口的模式下，「点图标面板被
///   窗口顶掉」每天都会发生，而访达双击是罕见路径，面板里的「打开主窗口」随时
///   可用。
private struct MainWindowRoot: View {
    var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: Design.Window.minWidth, minHeight: Design.Window.minHeight)
            .handleSelfCaptureRequest()
            // 文案来自全局查表，改语言不会让任何 @Observable 属性「看起来」变了，
            // SwiftUI 因此不会重算视图体。用一个显式的版本号做 identity，
            // 强制整棵树重建 —— 语言切换是极低频动作，这点代价无所谓。
            .id(model.languageRevision)
            .task {
                // 轮询在这里启动（幂等）。窗口关闭后它继续跑 ——
                // 这正是菜单栏能实时更新的前提。
                model.start()
            }
            .onAppear {
                guard model.isWindowPresentationExpected() else {
                    dismissWindow(id: "main")
                    return
                }
                model.windowDidAppear()
                // 窗口在，程序坞图标就该在（从菜单栏重新打开时恢复它）。
                NSApp.setActivationPolicy(.regular)
            }
            .onDisappear {
                model.windowDidDisappear()
                // 关掉窗口就退到「仅菜单栏」：常驻小工具挂着一个没有窗口的
                // 程序坞图标只会让人想去点它。轮询与会话都不受影响。
                NSApp.setActivationPolicy(.accessory)
            }
    }
}

/// 从「仅菜单栏」的后台模式回到前台并显示主窗口。
///
/// 顺序是刻意的：先在模型上登记（否则 MainWindowRoot 的拦截会把窗口当成擅自
/// 复活关掉）；激活策略必须在 openWindow **之前**改回 .regular，否则新窗口可能
/// 落到别的应用后面；最后再 activate 把焦点抢过来。
@MainActor
func presentMainWindow(_ model: AppModel, _ openWindow: OpenWindowAction) {
    model.expectWindowPresentation()
    NSApp.setActivationPolicy(.regular)
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
}

// MARK: - 已查清的启动限制（2026-11-06 插桩定位，结论留档）
//
//   * 对象：**裸可执行**（`swift build` / `swift run` 的产物，没有 bundle id）。
//   * 现象：macOS 26 实测启动时激活策略是 `.prohibited`，SwiftUI 对
//     「政策未升级」的 App 不实例化 Window 场景的窗口；即便提前把策略改成
//     `.regular`、甚至手动补发 activate，初始窗口也不出现 —— SwiftUI 只在
//     收到**显式 openWindow** 时才把 Window 场景实例化。
//   * 后果：dev 裸跑必须菜单栏 → 「打开主窗口」救一次；打包 .app 走
//     LaunchServices 的首次激活路径，不受影响（v0.1.5 一路验证过）。
//   * init() 里的 `.prohibited → .regular` 保留：它救不了初始窗口，但让
//     裸可执行在救回窗口后具有正常 App 的激活语义（didBecomeActive 等），
//     对打包版是无操作。插桩细节（11 个 NSStatusBarWindow 的杂音、
//     窗口清单快照）不必复现；若未来要再查，加回
//     `@NSApplicationDelegateAdaptor` + didFinishLaunching 打印即可。
