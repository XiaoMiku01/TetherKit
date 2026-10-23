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
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var menuBarController: MenuBarController?

    init() {
        // CI 冒烟与手动补建用的模式：建完 Finder 别名即退，不进 GUI。
        // 恒 exit 0 —— 别名建不上（受管机器之类）不该把流程判失败，结果打给
        // stdout。（brew 的 postinstall 也在沙箱里、写不了 /Applications ——
        // 实测确认 —— 所以正常安装路径靠下面的首次启动自动建立。）
        if CommandLine.arguments.dropFirst().contains("--install-finder-alias") {
            print(FinderAlias.ensure(for: Bundle.main.bundleURL))
            exit(0)
        }
        // 正常启动：后台顺手校一遍 —— 缺了就补，brew upgrade 换了 Cellar
        // 路径后目标漂移也会被重写。
        let bundleURL = Bundle.main.bundleURL
        Task.detached(priority: .utility) {
            FinderAlias.ensure(for: bundleURL)
        }
    }

    var body: some Scene {
        Window("TetherKit", id: "main") {
            MainWindowRoot(model: model)
                .background(MenuBarInstaller(model: model, controller: $menuBarController))
        }
        // 用 Window 而不是 WindowGroup：这是一个「设备连接面板」，开多个窗口
        // 没有意义，反而会让多个实例同时轮询同一个 helper。
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

/// 从 Window 场景取得真正的 openWindow 动作；控制器由 App 持有，关闭窗口不销毁。
private struct MenuBarInstaller: View {
    var model: AppModel
    @Binding var controller: MenuBarController?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear {
                guard controller == nil else { return }
                let appModel = model
                let action = openWindow
                controller = MenuBarController(model: appModel) {
                    presentMainWindow(appModel, action)
                }
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
