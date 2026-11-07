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
///
/// ★ Window ownership ★
///
///   The main window is an AppKit-managed window (`MainWindowManager`):
///   a plain NSWindow (fullSizeContentView, transparent, title hidden)
///   hosting SwiftUI. The window chrome comes from the executable's
///   `sdk` stamp, not from which layer owns the window; see
///   `MainWindowManager` and the linker settings in `Package.swift`.
@main
struct TetherKitApplication: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(TetherKitAppDelegate.self) private var appDelegate

    init() {
        // CI 冒烟与手动补建用的模式：建完 Finder 别名即退，不进 GUI。
        // 恒 exit 0 —— 别名建不上（受管机器之类）不该把流程判失败，结果打给
        // stdout。（brew 的 postinstall 也在沙箱里、写不了 /Applications ——
        // 实测确认 —— 所以正常安装路径靠下面的首次启动自动建立。）
        if CommandLine.arguments.dropFirst().contains("--install-finder-alias") {
            print(FinderAlias.ensure(for: Bundle.main.bundleURL))
            exit(0)
        }
        // Bare executables (swift build output, no bundle id) launch
        // with the .prohibited activation policy. The main window is
        // ours (MainWindowManager) and is presented by the delegate
        // once launch finishes; the policy still gates whether the app
        // can become key, so normalize it here. A packaged .app gets
        // .regular from LaunchServices and never hits this branch.
        if NSApplication.shared.activationPolicy() == .prohibited {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        TetherKitAppDelegate.launchModel = model
        // 正常启动：后台顺手校一遍 —— 缺了就补，brew upgrade 换了 Cellar
        // 路径后目标漂移也会被重写。
        let bundleURL = Bundle.main.bundleURL
        Task.detached(priority: .utility) {
            FinderAlias.ensure(for: bundleURL)
        }
    }

    var body: some Scene {
        // Persistent menu bar item: icon + live rate.
        // The .window style gives it a small panel, which can hold a
        // Language submenu and live values that menu items cannot.
        // Commands live on this scene — there is no Window scene
        // anymore; the main window belongs to AppKit (see
        // MainWindowManager).
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        .commands {
            // 「新建窗口」对单窗口应用没有意义，去掉免得用户点了没反应。
            CommandGroup(replacing: .newItem) {}
            // ⌘W: no Window scene means no built-in system Close, so
            // this menu item hides the main window and drops to
            // menu-bar mode (same as the red close button).
            CommandGroup(after: .newItem) {
                Button(L(.closeWindow)) { MainWindowManager.shared.closeMainWindow() }
                    .keyboardShortcut("w")
            }
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

/// Main window root: fixed-size content + poll startup.
///
/// The window itself is AppKit-managed (`MainWindowManager`); closing
/// it hides the window (orderOut, not destroy) and the app drops to
/// menu-bar mode.
struct MainWindowRoot: View {
    var model: AppModel

    var body: some View {
        ContentView(model: model)
            .frame(width: Design.Window.width, height: Design.Window.height)
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
    }
}

// MARK: - Launch-time window presentation
//
//   The main window is created and presented by the app delegate
//   (MainWindowManager), not by a SwiftUI scene. The model crosses
//   to the delegate through the static slot below: the adaptor hands
//   us an instance, but setting instance state on it from App.init
//   is init-order dependent, so the launch slot is the deterministic
//   channel.
final class TetherKitAppDelegate: NSObject, NSApplicationDelegate {
    static var launchModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model = Self.launchModel else { return }
        MainWindowManager.shared.present(model)
    }

    /// Double-clicking the app icon (e.g. in Finder) asks to reopen
    /// the window. SwiftUI's scene lifecycle never delivered this
    /// callback; reopen shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, let model = Self.launchModel {
            MainWindowManager.shared.present(model)
        }
        return true
    }

    /// Never quit just because the last window closed — the app is a
    /// menu-bar accessory by design. Close hides the window; the
    /// menu-bar item stays live.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
