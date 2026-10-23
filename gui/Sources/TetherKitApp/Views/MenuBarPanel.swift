import AppKit
import SwiftUI
import TetherKitIPC

/// 点开菜单栏项后的小面板。
///
/// 内容按「瞟一眼要知道什么」取舍：状态、速率、网卡与地址，再加两个动作
/// （打开主窗口、退出）。配置、图表、日志一律留在主窗口 —— 面板不是第二个界面。
struct MenuBarPanel: View {
    var model: AppModel
    var openMainWindow: () -> Void

    private var status: SessionStatus { model.status }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            header

            switch status.runState {
            case .running:
                runningDetails
            case .failed:
                if !status.fatalMessage.isEmpty {
                    Text(status.fatalMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            default:
                idleHint
            }

            Divider()
            actions
        }
        .padding(Design.Spacing.medium)
        .frame(width: 280)
        // 与主窗口同理：文案来自全局查表，改语言不会让任何 @Observable 属性
        // 「看起来」变了，得靠显式 identity 强制重建。面板本身会随轮询刷新，
        // 不加这行语言也会在下一个周期跟上 —— 但从面板里改语言时，用户盯着
        // 的就是这块面板，慢半拍会被当成没生效。
        .id(model.languageRevision)
    }

    private var header: some View {
        HStack(spacing: Design.Spacing.tight) {
            Circle()
                .fill(Design.accent(for: status.runState))
                .frame(width: 8, height: 8)
            Text(Design.statusLabel(for: status))
                .font(.headline)
            Spacer()
            if let duration = model.connectedDuration {
                Text(Format.duration(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var runningDetails: some View {
        speedRow(symbol: "arrow.down", caption: L(.downstreamShort),
                 bitsPerSecond: model.throughput.receiveBitsPerSecond, tint: .blue)
        speedRow(symbol: "arrow.up", caption: L(.upstreamShort),
                 bitsPerSecond: model.throughput.transmitBitsPerSecond, tint: .purple)

        if !status.systemInterface.isEmpty {
            Text("\(status.systemInterface) · "
                 + (model.networkState.hasAddress ? model.networkState.address
                                                  : L(.noIPConfigured)))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var idleHint: some View {
        Text(model.devices.isEmpty
             ? L(.menuBarNoDevice)
             : L(.menuBarReady, model.devices.first?.displayName ?? ""))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            HStack {
                Button(L(.openMainWindow)) {
                    openMainWindow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                // 仅菜单栏模式下这块面板是唯一入口，语言开关必须在这里也够得到 ——
                // 否则一个看不懂界面的用户，得先知道「要去 App 菜单」才能改语言，
                // 而在这个模式下 App 菜单只有把窗口开出来才看得见。
                languageMenu

                Button(L(.quit)) {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }

            if status.runState == .running {
                // 会话属于 helper，App 退出不影响它 —— 这一点必须说出来，
                // 否则用户会以为「退出 = 断网」而不敢点。
                Text(L(.quitTooltip))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 语言开关。选项写母语名字，不跟随界面语言翻译 —— 见 LanguageMenu 的说明。
    private var languageMenu: some View {
        Menu {
            Picker(L(.languageLabel), selection: Bindable(model).languagePreference) {
                Text(L(.languageSystem)).tag(LanguagePreference.system)
                Text(verbatim: "中文").tag(LanguagePreference.chinese)
                Text(verbatim: "English").tag(LanguagePreference.english)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L(.languageLabel))
    }

    private func speedRow(symbol: String, caption: String, bitsPerSecond: Double,
                          tint: Color) -> some View {
        HStack(spacing: Design.Spacing.small) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Format.bitrate(bitsPerSecond))
                .font(.callout.monospacedDigit())
                .foregroundStyle(tint)
        }
    }
}
