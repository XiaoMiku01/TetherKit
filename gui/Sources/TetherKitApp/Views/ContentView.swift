import SwiftUI
import TetherKitIPC

/// 主窗口根视图：按特权组件的可用性分流，可用时展示侧边栏框架。
///
/// ★ 布局的演进 ★
///
///   旧布局是单屏两栏仪表盘，当时刻意不用侧边栏 —— 那时整个 App 只有一件事
///   可做，「连接前配置」与「连上后观测」都塞在同一屏。改版后按页面分区：
///   连接（操作重心）、网络、吞吐、日志、管理，每页有自己的滚动 —— 页面越
///   分越细，侧边栏才从「多出的空层级」变成「必要的话题目录」。
///
///   `SidebarShell` 是分组后的骨架；本文件只剩两件事：
///
///   1. **按 helper 可用性分流**：探测中 / 未安装 / 版本不齐 / 可用，四选一。
///      前三种是新手最先撞上的画面，必须整页接管而不是出现在侧边栏某页里
///      （页面上什么都点不动，侧边栏反而成了噪音）。
///   2. **全局弹窗**：操作失败、检查更新结果。属窗口级而无论在哪一页。
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            switch model.helperAvailability {
            case .unknown:
                gatingPage(ProbingCard(), proxy)
            case .missing(let reason):
                gatingPage(HelperMissingCard(model: model, reason: reason), proxy)
            case .outdated(let installed, let expected):
                gatingPage(HelperOutdatedCard(model: model,
                                              installed: installed,
                                              expected: expected), proxy)
            case .available:
                SidebarShell(model: model)
            }
        }
        .background(backgroundGradient)
        .animation(.smooth(duration: 0.25), value: model.status.runState)
        .animation(.smooth(duration: 0.25), value: model.helperAvailability)
        .alert(L(.alertOperationFailed),
               isPresented: Binding(get: { model.alertMessage != nil },
                                    set: { if !$0 { model.alertMessage = nil } })) {
            Button(L(.ok)) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert(L(.updateCheckTitle),
               isPresented: Binding(get: { model.updateCheckResult != nil },
                                    set: { if !$0 { model.updateCheckResult = nil } })) {
            if case .updateAvailable(let release) = model.updateCheckResult {
                Button(L(.openReleasePage)) { NSWorkspace.shared.open(release.pageURL) }
                Button(L(.copyBrewUpgradeCommand)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew upgrade tetherkit", forType: .string)
                }
                Button(L(.ok), role: .cancel) {}
            } else {
                Button(L(.ok), role: .cancel) {}
            }
        } message: {
            Text(updateCheckDescription)
        }
    }

    /// helper 在探测 / 未安装 / 版本不齐时的整页容器。
    ///
    /// 三种状态都只有一张卡，居中偏上放在窗口背景上；`minHeight` 让卡片
    /// 区域撑满可视区（与整个窗口共用背景渐变），`basedOnSize` 保证
    /// 内容放得下时完全不滚动、不回弹。
    private func gatingPage(_ card: some View, _ proxy: GeometryProxy) -> some View {
        ScrollView {
            card
                .padding(Design.Spacing.large)
                .frame(minHeight: proxy.size.height, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// 「检查更新」弹窗的正文。
    ///
    /// brew 命令名与 tap 里实际的 GUI formula（tetherkit）一致 —— CLI 更名
    /// tetherkit-cli 时这个名字让给了 GUI；手动构建的用户按第二句走。
    private var updateCheckDescription: String {
        switch model.updateCheckResult {
        case .upToDate(let current):
            return L(.updateUpToDate, current)
        case .updateAvailable(let release):
            return L(.updateAvailable, release.version)
        case .failed(let reason):
            return L(.updateCheckFailed, reason)
        case .unavailable:
            return L(.updateDevBuild)
        case nil:
            return ""
        }
    }

    /// 背景用一层随状态变化的极淡渐变。
    ///
    /// 强度刻意压得很低（0.10 / 0.04）：它的作用是让「连上了」这件事在余光里
    /// 也能被感知，而不是抢内容的注意力。侧边栏页自带底色，渐变只在
    /// helper 未就绪的整页与侧边栏背后的兜底可见。
    private var backgroundGradient: some View {
        let accent = Design.accent(for: model.status.runState)
        return LinearGradient(
            colors: [accent.opacity(0.10), accent.opacity(0.04), .clear],
            startPoint: .top,
            endPoint: .bottom)
        .ignoresSafeArea()
    }
}

/// 正在探测 helper 时的占位。
private struct ProbingCard: View {
    var body: some View {
        Card {
            HStack(spacing: Design.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                Text(L(.checkingHelper))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Design.Spacing.large)
        }
    }
}

/// helper 没装时的引导。
///
/// 这是新用户最可能撞上的一屏，所以把「为什么需要」说清楚之后直接给一个
/// 「安装」按钮 —— 弹一次系统授权框就装好。终端方案降级成折叠里的备选。
private struct HelperMissingCard: View {
    @Bindable var model: AppModel
    let reason: String

    var body: some View {
        Card(title: L(.needInstallTitle), systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                Text(L(.needInstallBody))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HelperInstallSection(
                    model: model,
                    buttonTitle: L(.installHelperButton),
                    detail: L(.installHelperDetail))

                DisclosureGroup(L(.showConnectFailureDetail)) {
                    Text(reason)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Design.Spacing.tight)
                }
                .font(.caption)
            }
        }
    }
}

/// 装着的 helper 与当前 App 的 XPC 接口对不上。
///
/// 单独一屏而不是复用「没安装」：这两种情况下用户要做的事不一样，而且如果不
/// 明说，症状会表现成调用卡住或直接崩溃 —— 那是最难自查的一类问题。
private struct HelperOutdatedCard: View {
    @Bindable var model: AppModel
    let installed: Int
    let expected: Int

    var body: some View {
        Card(title: L(.helperNeedsUpdateTitle), systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                Text(L(.helperNeedsUpdateBody, String(installed), String(expected)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HelperInstallSection(
                    model: model,
                    buttonTitle: L(.updateHelperButton),
                    detail: L(.updateHelperDetail))
            }
        }
    }
}

/// 「一键安装」按钮 + 终端备选方案。missing / outdated 两张卡共用。
///
/// 终端方案必须保留而不是彻底删掉：`swift run` 跑的裸可执行文件没有内嵌载荷，
/// 按钮会明确报错引导到脚本；也总有人就是不愿意往 App 弹的框里输密码。
private struct HelperInstallSection: View {
    @Bindable var model: AppModel
    let buttonTitle: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack(spacing: Design.Spacing.small) {
                Button {
                    Task { await model.installHelper() }
                } label: {
                    HStack(spacing: Design.Spacing.tight) {
                        if model.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(model.isBusy ? L(.installingProgress) : buttonTitle)
                    }
                    .frame(minWidth: 132)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy)

                Text(L(.authorizationPromptHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(L(.installViaTerminal)) {
                VStack(alignment: .leading, spacing: Design.Spacing.tight) {
                    CopyableCommand(command: "sudo ./gui/Scripts/install-helper.sh")
                    Text(L(.installViaTerminalHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, Design.Spacing.tight)
            }
            .font(.caption)
        }
    }
}

/// 一条可复制的命令。
struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                // 2 秒后复原。给的是「已复制」这个确认，不是一个需要用户操作的状态。
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(L(copied ? .copied : .copy), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(L(copied ? .copiedToClipboard : .copyCommand))
        }
        .padding(Design.Spacing.small)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Design.Radius.control))
    }
}
