import SwiftUI
import TetherKitIPC

/// 「管理」页：特权组件的安装状态与维护动作。
///
/// 内容全部来自旧布局里挤在主界面左栏底部的那条 caption 尾注 —— 页面化之后
/// 它终于有空间说清自己在维护什么。逻辑与 `AppModel` 的交互一字未改：
/// 安装 / 更新走 `installHelper()`，确认弹窗规则也不变（跑着会话时更新要先问）。
struct ManagePage: View {
    @Bindable var model: AppModel

    /// 卸载是破坏性动作（断开连接、删系统文件），必须先确认。
    @State private var confirmingHelperUninstall = false

    /// 更新组件时**正跑着会话**才需要确认 —— 安装脚本会先 bootout 旧组件，
    /// 那一下会把连接掐掉。空闲时更新什么都不会毁，再拦一道只会给本来就该
    /// 尽快做的事平添阻力。
    @State private var confirmingHelperUpdate = false

    var body: some View {
        Card(title: L(.manageHelperSectionTitle), systemImage: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                stateRows
                Divider()
                uninstallRow
            }
        }
        .confirmationDialog(L(.confirmUninstallTitle), isPresented: $confirmingHelperUninstall) {
            Button(L(.uninstall), role: .destructive) {
                Task { await model.uninstallHelper() }
            }
            Button(L(.cancel), role: .cancel) {}
        } message: {
            Text(uninstallWarning)
        }
        .confirmationDialog(L(.confirmHelperUpdateTitle), isPresented: $confirmingHelperUpdate) {
            Button(L(.updateHelperButton)) {
                Task { await model.installHelper() }
            }
            Button(L(.cancel), role: .cancel) {}
        } message: {
            Text(L(.helperUpdateWhileRunningWarning))
        }
    }

    private var uninstallWarning: String {
        let base = L(.uninstallExplanation)
        return model.status.runState == .running
            ? L(.uninstallWhileRunningWarning) + base
            : base
    }

    /// 组件版本与更新入口。版本不一致时这一块从「参考信息」变成「有件事
    /// 等着你做」：两个版本号一起摆出来，颜色也从 tertiary 提到 orange。
    @ViewBuilder
    private var stateRows: some View {
        if case .available(let version) = model.helperAvailability {
            if let mismatch = model.helperVersionMismatch {
                HStack(alignment: .center, spacing: Design.Spacing.small) {
                    Text(L(.helperVersionMismatch, mismatch.installed, mismatch.expected))
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: Design.Spacing.small)
                    // 忙的时候换成「正在安装……」而不是只把按钮置灰：授权框关掉
                    // 之后要等好几秒（bootout → 拷文件 → bootstrap → 探活），
                    // 一个灰掉的按钮看起来像是点了没反应。
                    Button(model.isBusy ? L(.installingProgress) : L(.updateHelperButton)) {
                        requestHelperUpdate()
                    }
                    .disabled(model.isBusy)
                    .help(L(.helperVersionMismatchTooltip, mismatch.installed, mismatch.expected))
                }
            } else {
                HStack(alignment: .center, spacing: Design.Spacing.small) {
                    Text(L(.helperComponentVersion, version))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: Design.Spacing.small)
                    if let update = model.availableUpdate {
                        // 版本一致但 GitHub 上有新 Release：升级要去终端敲 brew，
                        // 只是「知道一下」。与版本不一致互斥展示 ——
                        // 版本不一致是当场点一下就能解决的，让位给它。
                        Button(L(.helperUpdateBadge, update.version)) {
                            model.updateCheckResult = .updateAvailable(update)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    /// 卸载入口。极低频的管理动作：低调，但必须有 —— 不然组件「装得上、
    /// 删不掉」，只能回终端翻脚本。
    private var uninstallRow: some View {
        HStack(alignment: .center, spacing: Design.Spacing.small) {
            Text(L(.uninstallExplanation))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Design.Spacing.small)
            Button(L(.uninstallHelperMenuItem)) { confirmingHelperUninstall = true }
                .disabled(model.isBusy)
        }
    }

    /// 「更新特权组件」被点了。跑着会话才先确认 —— 见 `confirmingHelperUpdate`。
    private func requestHelperUpdate() {
        if model.status.runState == .running {
            confirmingHelperUpdate = true
        } else {
            Task { await model.installHelper() }
        }
    }
}
