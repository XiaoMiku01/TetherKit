import SwiftUI
import TetherKitIPC

/// Main window root view: gates on helper availability, then shows
/// the sidebar shell once the helper is ready.
///
/// `SidebarShell` is the skeleton; this file keeps two jobs:
///
///   1. Gate on helper availability: probing / missing / outdated /
///      ready. The first three are the screens new users hit first,
///      so they must take over the entire window instead of appearing
///      inside one sidebar page (nothing is tappable there anyway,
///      and the sidebar would just be noise).
///   2. Window-level alerts: operation failures and update-check
///      results. They belong to the window, whatever page is showing.
struct ContentView: View {
    var model: AppModel

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

    /// Full-page container for the probing / missing / outdated
    /// helper states.
    ///
    /// All three states show a single card at the top of the window,
    /// on the shared background. `minHeight` fills the visible area
    /// and `basedOnSize` suppresses scrolling and bounce while the
    /// content fits.
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

    /// A very faint gradient behind everything, tinted by session
    /// state.
    ///
    /// Kept deliberately faint (0.10 / 0.04): its job is to make
    /// "connected" perceptible in peripheral vision, not to compete
    /// with content. Sidebar pages carry their own background
    /// material; the gradient remains visible only on the
    /// helper-not-ready full pages and as fallback behind the sidebar.
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
    var model: AppModel
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
    var model: AppModel
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
    var model: AppModel
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
